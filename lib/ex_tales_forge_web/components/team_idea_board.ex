defmodule TalesForgeWeb.TeamIdeaBoard do
  @moduledoc """
  The founders' idea board on /team (`#idea-board`; design: tales-forge-docs
  `docs/design-idea-board.md`). A LiveComponent over `TalesForge.Board`:
  add ideas, vote +1/-1 (again to take it back), comment (with `@case`,
  `@bobby`, `@gentry` to wake a bot), add links, fill in Case's refinement,
  and move cards.

  Moving: drag a card onto a column (the `TeamPage` hook, `assets/js/team_hooks.js`),
  or, with a keyboard or on a phone, the card's "Move to" form, which lists only
  the moves `TalesForge.Board.Transitions` allows a founder (with the reason for the others). The gates are checked
  again on every move; a refusal (for example "Needs an upvote.")
  shows as a message on the card.

  Layout: Ideas (the backlog) on the left, the three active columns (Refining,
  Founder check, Building) in the middle with Parked under them across their
  width, Done on the right. Every card is thin (Fredrik, 2026-10-10): the
  avatar, the full title (it wraps, no ellipsis), the compact "needs work" badge and
  can't-move reason, and a vote row inside the card (thumbs up and thumbs
  down, each with its own count, no net number; siblings of the open button, so a vote never opens the card). Each area has a fixed height and scrolls on its
  own; on a phone the areas stack. A card's avatar is a 5×5 identicon seeded
  from its id (`avatar_spec/1`, aria-hidden).

  Clicking a card opens it in full in a modal dialog (`role="dialog"`, focus
  trapped by `focus_wrap`, Esc or clicking outside closes it, focus returns to
  the card): votes, the open -1 block, Move to, Case's refinement, links,
  images (`TalesForgeWeb.TeamImages`: paste, drop, pick or "Capture screen",
  with a note), comments and history. The parent LiveView forwards `{:board, :changed}` as
  `send_update(refresh: true)`; an open card stays open and refreshes.
  """
  use TalesForgeWeb, :live_component

  alias TalesForge.Board
  alias TalesForge.Board.{Idea, Mentions, Transitions, Typing}
  alias TalesForgeWeb.TeamImages

  # The sort choices for the Ideas column: {URL value, label}.
  @sorts [
    {"top", "Most support"},
    {"newest", "Newest"},
    {"oldest", "Oldest"},
    {"votes", "Most votes"}
  ]
  @sort_keys Enum.map(@sorts, &elem(&1, 0))

  @impl true
  def update(%{refresh: true}, socket), do: {:ok, load(socket)}

  # A few seconds after the last keystroke the typing hint goes.
  def update(%{typing_expire: {id, at}}, socket) do
    if socket.assigns.typed[id] == at do
      Typing.stop(id, socket.assigns.founder)
      {:ok, assign(socket, :typed, Map.delete(socket.assigns.typed, id))}
    else
      {:ok, socket}
    end
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:errors, fn -> %{} end)
     |> assign_new(:form_error, fn -> nil end)
     |> assign_new(:open_id, fn -> nil end)
     |> assign_new(:comment_for, fn -> nil end)
     |> assign_new(:downvote_for, fn -> nil end)
     |> assign_new(:editing, fn -> nil end)
     |> assign_new(:drafts, fn -> %{} end)
     |> assign(:sorts, @sorts)
     |> assign_new(:typed, fn -> %{} end)
     |> TeamImages.allow(:card_images)
     |> load()}
  end

  @doc """
  The sort key for the Ideas column from the `sort` URL query value.
  An unknown or missing value gives `"top"` (the board's ranking).

      iex> TalesForgeWeb.TeamIdeaBoard.sort_key("newest")
      "newest"
      iex> TalesForgeWeb.TeamIdeaBoard.sort_key("other")
      "top"
  """
  @spec sort_key(term()) :: String.t()
  def sort_key(key) when key in @sort_keys, do: key
  def sort_key(_key), do: "top"

  # Puts the Ideas cards in the selected order. "top" keeps the board's ranking.
  # Equal values keep the ranking order (Enum.sort_by is stable).
  defp sort_ideas(cards, "newest"),
    do: Enum.sort_by(cards, & &1.inserted_at, {:desc, DateTime})

  defp sort_ideas(cards, "oldest"),
    do: Enum.sort_by(cards, & &1.inserted_at, {:asc, DateTime})

  defp sort_ideas(cards, "votes"), do: Enum.sort_by(cards, &length(&1.votes), :desc)
  defp sort_ideas(cards, _top), do: cards

  @doc """
  The "Written by" value of a card author: the first part of the email, in
  lower case. Bots give nil.

      iex> TalesForgeWeb.TeamIdeaBoard.author_key("Fredrik@whyse.se")
      "fredrik"
      iex> TalesForgeWeb.TeamIdeaBoard.author_key("bot:case")
      nil
  """
  @spec author_key(String.t() | nil) :: String.t() | nil
  def author_key("bot:" <> _), do: nil

  def author_key(email) when is_binary(email),
    do: email |> String.downcase() |> String.split(["@", ".", "+"]) |> hd()

  def author_key(_), do: nil

  # The "Written by" choices: each founder who wrote a card, {value, name}.
  defp authors(board) do
    board
    |> Map.values()
    |> List.flatten()
    |> Enum.map(& &1.author)
    |> Enum.uniq_by(&author_key/1)
    |> Enum.flat_map(fn a ->
      case author_key(a) do
        nil -> []
        key -> [{key, TalesForge.TeamOnline.name(a)}]
      end
    end)
    |> Enum.sort_by(&elem(&1, 1))
  end

  # Keeps the Ideas cards of one author ("" or nil: all).
  defp by_author(cards, by) when by in [nil, ""], do: cards
  defp by_author(cards, by), do: Enum.filter(cards, &(author_key(&1.author) == by))

  # Keeps the Ideas cards where a comment @mentions `handle` (only @mentions,
  # as the card asks; `@founders` mentions every founder).
  defp mentioning(cards, false, _handle), do: cards
  defp mentioning(_cards, true, nil), do: []

  defp mentioning(cards, true, handle) do
    Enum.filter(cards, fn card ->
      Enum.any?(card.comments, &(handle in Mentions.parse(&1.body).founders))
    end)
  end

  defp load(socket) do
    sort = sort_key(socket.assigns[:ideas_sort])
    by = socket.assigns[:ideas_by]
    mine = socket.assigns[:ideas_mine] == true
    me = Mentions.handle_for(socket.assigns[:login])
    full = Board.board()

    board =
      Map.update(full, "ideas", [], fn cards ->
        cards |> sort_ideas(sort) |> by_author(by) |> mentioning(mine, me)
      end)

    socket = assign(socket, :authors, authors(full))
    open_id = socket.assigns[:open_id]
    open = open_id && board |> Map.values() |> List.flatten() |> Enum.find(&(&1.id == open_id))

    assign(socket,
      board: board,
      prs: prs(),
      pings: Board.unread_pings(socket.assigns[:login]),
      typing: Typing.who(),
      open: open
    )
  end

  defp actor(socket), do: {:founder, socket.assigns.founder}

  defp result(socket, id, {:ok, _}),
    do: {:noreply, socket |> assign(:errors, Map.delete(socket.assigns.errors, id)) |> load()}

  defp result(socket, id, {:error, %Ecto.Changeset{} = cs}),
    do: result(socket, id, {:error, changeset_text(cs)})

  defp result(socket, id, {:error, msg}),
    do:
      {:noreply,
       socket |> assign(:errors, Map.put(socket.assigns.errors, id, to_string(msg))) |> load()}

  defp changeset_text(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {m, _} -> m end)
    |> Enum.map_join("; ", fn {k, v} -> "#{k} #{Enum.join(v, ", ")}" end)
  end

  # A refused move (for example a drag that needs a comment) opens the card,
  # so the founder sees the reason; a done move closes the comment box.
  defp move(socket, id, to, note) do
    case save_drafts(socket, id) do
      {:ok, socket} -> do_move(socket, id, to, note)
      {:error, socket, msg} -> {:noreply, socket |> assign(:open_id, id) |> put_error(id, msg)}
    end
  end

  defp put_error(socket, id, msg),
    do: socket |> assign(:errors, Map.put(socket.assigns.errors, id, msg)) |> load()

  # Saves the card's answer drafts (all of them together) and forgets them.
  defp save_drafts(socket, id) do
    mine = for {{^id, q}, d} <- socket.assigns.drafts, do: {q, d}

    with [_ | _] <- mine,
         %Idea{} = idea <- Board.get_idea(id),
         {:ok, _} <- Board.save_answers(idea, socket.assigns.founder, mine) do
      {:ok,
       assign(socket, :drafts, Map.reject(socket.assigns.drafts, fn {{i, _}, _} -> i == id end))}
    else
      [] -> {:ok, socket}
      nil -> {:ok, socket}
      {:error, msg} -> {:error, socket, to_string(msg)}
    end
  end

  defp do_move(socket, id, to, note) do
    case with_idea(socket, id, &Board.move(&1, actor(socket), to, note)) do
      {:noreply, %{assigns: %{errors: %{^id => _}}} = s} ->
        {:noreply, s |> assign(:open_id, id) |> load()}

      {:noreply, s} ->
        {:noreply, s |> assign(:comment_for, nil) |> load()}
    end
  end

  defp with_idea(socket, id, fun) do
    case Board.get_idea(id) do
      %Idea{} = idea -> result(socket, id, fun.(idea))
      nil -> result(socket, id, {:error, "That card is gone."})
    end
  end

  @impl true
  def handle_event("sort", params, socket) do
    query =
      [
        {"sort", sort_key(params["sort"])},
        {"by", params["by"]},
        {"mine", if(params["mine"] == "true", do: "1")}
      ]
      |> Enum.reject(fn {k, v} -> v in [nil, ""] or {k, v} == {"sort", "top"} end)

    path = if query == [], do: "/team", else: "/team?" <> URI.encode_query(query)
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("open", %{"card_id" => id}, socket) do
    Board.read_pings(id, socket.assigns[:login])
    {:noreply, socket |> assign(:open_id, id) |> load()}
  end

  def handle_event("close", _params, socket) do
    if id = socket.assigns.open_id, do: Typing.stop(id, socket.assigns.founder)

    socket =
      case socket.assigns.open_id && save_drafts(socket, socket.assigns.open_id) do
        {:error, s, _msg} -> s
        {:ok, s} -> s
        _ -> socket
      end

    {:noreply,
     assign(socket, open_id: nil, open: nil, comment_for: nil, downvote_for: nil, editing: nil)}
  end

  # Back / Forward / On hold. A move that needs a comment opens the comment box.
  def handle_event("step", %{"card_id" => id, "to" => to} = params, socket) do
    if params["needs_comment"] == "true",
      do: {:noreply, socket |> assign(comment_for: {id, to}) |> load()},
      else: move(socket, id, to, nil)
  end

  def handle_event("cancel_comment", _params, socket),
    do: {:noreply, socket |> assign(:comment_for, nil) |> load()}

  def handle_event("downvote", %{"card_id" => id, "reason" => reason}, socket) do
    case with_idea(socket, id, &Board.vote(&1, socket.assigns.founder, -1, reason)) do
      {:noreply, %{assigns: %{errors: %{^id => _}}}} = answer -> answer
      {:noreply, s} -> {:noreply, s |> assign(:downvote_for, nil) |> load()}
    end
  end

  def handle_event("cancel_downvote", _params, socket),
    do: {:noreply, socket |> assign(:downvote_for, nil) |> load()}

  def handle_event("edit_refinement", %{"card_id" => id}, socket),
    do: {:noreply, socket |> assign(:editing, id) |> load()}

  def handle_event("cancel_refinement", _params, socket),
    do: {:noreply, socket |> assign(:editing, nil) |> load()}

  def handle_event("add", %{"idea" => attrs}, socket) do
    case Board.create_idea(socket.assigns.founder, attrs) do
      {:ok, _} -> {:noreply, socket |> assign(:form_error, nil) |> load()}
      {:error, cs} -> {:noreply, assign(socket, :form_error, changeset_text(cs))}
    end
  end

  # The vote travels as phx-value-vote, never "value": a <button>'s own
  # (empty) value attribute overrides phx-value-value in the browser.
  def handle_event("vote", %{"card_id" => id, "vote" => vote}, socket) do
    case Integer.parse(to_string(vote)) do
      # A new -1 needs a reason: open the card with the reason box.
      {-1, ""} ->
        case Board.get_idea(id) do
          %Idea{} = idea ->
            if Board.vote_of(idea, socket.assigns.founder) == -1,
              do: with_idea(socket, id, &Board.vote(&1, socket.assigns.founder, -1)),
              else: {:noreply, socket |> assign(open_id: id, downvote_for: id) |> load()}

          nil ->
            result(socket, id, {:error, "That card is gone."})
        end

      {1, ""} ->
        with_idea(socket, id, &Board.vote(&1, socket.assigns.founder, 1))

      _ ->
        result(socket, id, {:error, "A vote is +1 or -1."})
    end
  end

  def handle_event("move", %{"card_id" => id, "to" => to} = params, socket) do
    note = params["note"] |> to_string() |> String.trim()
    move(socket, id, to, if(note == "", do: nil, else: note))
  end

  def handle_event("answer_pr", %{"card_id" => id, "answer" => answer} = params, socket) do
    answer = %{"approve" => :approve, "request_changes" => :request_changes}[answer]

    if answer,
      do:
        with_idea(
          socket,
          id,
          &Board.answer_pr(&1, socket.assigns.founder, answer, params["comment"])
        ),
      else: result(socket, id, {:error, "Approve or request changes."})
  end

  # The answer boxes: what the founder types is kept as a draft (client state)
  # and saved with the next move, on close, or on blur.
  def handle_event("draft_answers", %{"card_id" => id} = params, socket) do
    qs = params["questions"] || %{}

    drafts =
      Enum.reduce(params["answers"] || %{}, socket.assigns.drafts, fn {i, text}, acc ->
        case qs[i] do
          nil -> acc
          q -> Map.update(acc, {id, q}, %{"answer" => text}, &Map.put(&1, "answer", text))
        end
      end)

    {:noreply, socket |> assign(:drafts, drafts) |> load()}
  end

  def handle_event("toggle_defer", %{"card_id" => id, "question" => q, "deferred" => d}, socket) do
    drafts =
      Map.update(
        socket.assigns.drafts,
        {id, q},
        %{"deferred" => d == "true"},
        &Map.put(&1, "deferred", d == "true")
      )

    {:noreply, socket |> assign(:drafts, drafts) |> load()}
  end

  def handle_event("save_answers", %{"card_id" => id}, socket) do
    case save_drafts(socket, id) do
      {:ok, socket} -> {:noreply, load(socket)}
      {:error, socket, msg} -> result(socket, id, {:error, msg})
    end
  end

  def handle_event("validate_images", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_image", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :card_images, ref)}

  def handle_event("add_images", %{"card_id" => id} = params, socket) do
    images = TeamImages.read_all(socket, :card_images)

    with_idea(socket, id, &Board.add_images(&1, socket.assigns.founder, images, params["note"]))
  end

  def handle_event("comment", %{"card_id" => id, "body" => body}, socket) do
    Typing.stop(id, socket.assigns.founder)

    with_idea(
      assign(socket, :typed, Map.delete(socket.assigns.typed, id)),
      id,
      &Board.add_comment(&1, socket.assigns.founder, body, login: socket.assigns[:login])
    )
  end

  # Typing in the comment box: the others see "<name> is typing…" (a hint,
  # not a lock). It goes 5 seconds after the last keystroke.
  def handle_event("typing", %{"card_id" => id} = params, socket) do
    if String.trim(to_string(params["body"])) == "" do
      Typing.stop(id, socket.assigns.founder)
      {:noreply, assign(socket, :typed, Map.delete(socket.assigns.typed, id))}
    else
      at = System.monotonic_time()
      Typing.start(id, socket.assigns.founder)

      send_update_after(
        __MODULE__,
        [id: socket.assigns.id, typing_expire: {id, at}],
        Application.get_env(:ex_tales_forge, :board_typing_ms, 5_000)
      )

      {:noreply, assign(socket, :typed, Map.put(socket.assigns.typed, id, at))}
    end
  end

  def handle_event("refine", %{"card_id" => id} = params, socket) do
    attrs = %{
      "details" => params["details"],
      "open_questions" =>
        params["open_questions"]
        |> to_string()
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "")),
      "rough_cost" => params["rough_cost"],
      "verdict" => params["verdict"]
    }

    attrs = Map.reject(attrs, fn {_k, v} -> v in [nil, ""] end)

    case with_idea(socket, id, &Board.refine(&1, attrs)) do
      {:noreply, %{assigns: %{errors: %{^id => _}}}} = answer -> answer
      {:noreply, s} -> {:noreply, s |> assign(:editing, nil) |> load()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="team-idea-board space-y-5" data-board-target={"##{@id}"}>
      <section
        :if={@pings != []}
        id="board-pings"
        aria-labelledby="board-pings-title"
        class="team-card rounded-xl border border-[var(--paper-accent)] p-3"
      >
        <h3 id="board-pings-title" class="text-sm font-semibold">
          Pings for you
          <span class="badge badge-primary badge-sm ml-1" data-role="ping-count">
            {Enum.sum(Enum.map(@pings, & &1.count))}
          </span>
        </h3>
        <ul class="mt-1 flex flex-wrap gap-2">
          <li :for={p <- @pings}>
            <button
              type="button"
              id={"ping-#{p.idea_id}"}
              phx-click="open"
              phx-value-card_id={p.idea_id}
              phx-target={@myself}
              class="min-h-11 rounded border px-3 text-left text-sm"
            >
              <span class="font-semibold">{p.title}</span>
              <span class="text-xs text-[var(--paper-muted)]">
                from {who(p.from)}{if p.count > 1, do: " (#{p.count})"}
              </span>
            </button>
          </li>
        </ul>
      </section>
      <form
        id="board-add"
        phx-submit="add"
        phx-target={@myself}
        class="team-card grid gap-2 rounded-xl p-4 sm:grid-cols-[minmax(0,1fr)_minmax(0,2fr)_auto] sm:items-end"
      >
        <label class="grid gap-1 text-sm font-semibold">
          New idea
          <input
            name="idea[title]"
            required
            maxlength="200"
            placeholder="A short title"
            class="rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-3 py-2 font-normal"
          />
        </label>
        <label class="grid gap-1 text-sm font-semibold">
          A sentence or two (optional) <textarea
            name="idea[body]"
            rows="1"
            class="rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-3 py-2 font-normal"
          ></textarea>
        </label>
        <button type="submit" class="team-cta min-h-11 rounded-full px-5 font-semibold">Add idea</button>
        <p :if={@form_error} role="alert" class="text-sm text-red-700 sm:col-span-3">{@form_error}</p>
      </form>

      <%!-- Desktop: Ideas left, the three active columns in the middle with
           Parked under them, Done right. Phone: the areas stack. Each area
           has a fixed height and scrolls on its own. --%>
      <div
        id="board-columns"
        class="grid gap-3 lg:grid-cols-[15rem_minmax(0,1fr)_15rem] lg:grid-rows-[28rem_12rem]"
      >
        <.area
          column="ideas"
          sorts={@sorts}
          sort={sort_key(@ideas_sort)}
          authors={@authors}
          by={assigns[:ideas_by]}
          mine={assigns[:ideas_mine] == true}
          size={:thin}
          prs={@prs}
          typing={@typing}
          board={@board}
          founder={@founder}
          myself={@myself}
          class="lg:row-span-2"
        />
        <div class="grid min-w-0 gap-3 lg:col-start-2 lg:row-start-1 lg:grid-cols-3">
          <.area
            :for={c <- ~w(refining check building)}
            column={c}
            size={:thin}
            prs={@prs}
            typing={@typing}
            board={@board}
            founder={@founder}
            myself={@myself}
          />
        </div>
        <.area
          column="parked"
          size={:thin}
          prs={@prs}
          typing={@typing}
          board={@board}
          founder={@founder}
          myself={@myself}
          class="lg:col-start-2 lg:row-start-2"
        />
        <.area
          column="done"
          size={:thin}
          prs={@prs}
          typing={@typing}
          board={@board}
          founder={@founder}
          myself={@myself}
          class="lg:col-start-3 lg:row-start-1 lg:row-span-2"
        />
      </div>

      <div
        :if={@open}
        id="board-modal"
        class="fixed inset-0 z-50 flex items-end justify-center bg-black/40 sm:items-center sm:p-4"
        phx-window-keydown={close_js(@myself)}
        phx-key="Escape"
      >
        <.focus_wrap
          id="board-modal-panel"
          role="dialog"
          aria-modal="true"
          aria-labelledby="board-modal-title"
          phx-click-away={close_js(@myself)}
          class="max-h-[92dvh] w-full max-w-2xl overflow-y-auto rounded-t-2xl bg-[var(--paper-panel)] p-4 text-[var(--paper-ink)] shadow-xl sm:rounded-2xl sm:p-6"
        >
          <div class="flex justify-end">
            <button
              type="button"
              id="board-modal-close"
              phx-click={close_js(@myself)}
              aria-label="Close card"
              class="min-h-11 min-w-11 rounded border px-2"
            >
              ✕
            </button>
          </div>
          <.card
            idea={@open}
            founder={@founder}
            myself={@myself}
            error={@errors[@open.id]}
            prs={@prs}
            comment_for={@comment_for}
            downvote_for={@downvote_for}
            editing={@editing}
            drafts={@drafts}
            typing={@typing}
            uploads={@uploads}
          />
        </.focus_wrap>
      </div>
    </div>
    """
  end

  defp close_js(myself), do: JS.push("close", target: myself) |> JS.pop_focus()

  defp open_js(myself, id),
    do: JS.push_focus() |> JS.push("open", value: %{card_id: id}, target: myself)

  attr :column, :string, required: true
  attr :founder, :string, required: true
  attr :size, :atom, required: true
  attr :board, :map, required: true
  attr :prs, :map, default: %{}
  attr :typing, :map, default: %{}
  attr :myself, :any, required: true
  attr :class, :string, default: nil
  attr :sorts, :list, default: nil
  attr :sort, :string, default: "top"
  attr :authors, :list, default: []
  attr :by, :string, default: nil
  attr :mine, :boolean, default: false

  defp area(assigns) do
    assigns = assign(assigns, :cards, assigns.board[assigns.column])

    ~H"""
    <section
      id={"board-col-#{@column}"}
      data-board-column={@column}
      aria-labelledby={"board-col-#{@column}-title"}
      class={[
        "team-board-column flex min-h-0 min-w-0 flex-col rounded-xl border border-[var(--paper-rule)] bg-[var(--paper-margin)] p-2",
        "h-[22rem] lg:h-auto [&.is-drop-target]:ring-2 [&.is-drop-target]:ring-[var(--paper-accent)] [&[data-accepts=false]]:opacity-50",
        @column == "parked" && "h-[12rem]",
        @class
      ]}
    >
      <h3
        id={"board-col-#{@column}-title"}
        class="flex items-baseline justify-between px-1 pb-1 font-serif text-base font-bold"
      >
        {Transitions.label(@column)}
        <span class="font-sans text-xs font-normal text-[var(--paper-muted)]">{length(@cards)}</span>
      </h3>
      <%!-- The Ideas toolbar: labels sit outside the controls; the row wraps
           in a narrow column, with no absolute positioning. --%>
      <form
        :if={@sorts}
        id="ideas-sort"
        phx-change="sort"
        phx-target={@myself}
        class="flex flex-wrap items-end gap-2 px-1 pb-2 text-xs text-[var(--paper-muted)]"
      >
        <div class="flex min-w-[7rem] flex-1 flex-col gap-0.5">
          <label for="ideas-sort-select">Sort</label>
          <select
            id="ideas-sort-select"
            name="sort"
            class="select select-sm w-full min-w-0 bg-[var(--paper-panel)] text-[var(--paper-ink)]"
          >
            <option :for={{key, label} <- @sorts} value={key} selected={key == @sort}>{label}</option>
          </select>
        </div>
        <div class="flex min-w-[7rem] flex-1 flex-col gap-0.5">
          <label for="ideas-by">Author</label>
          <select
            id="ideas-by"
            name="by"
            class="select select-sm w-full min-w-0 bg-[var(--paper-panel)] text-[var(--paper-ink)]"
          >
            <option value="">Everyone</option>
            <option :for={{key, name} <- @authors} value={key} selected={key == @by}>{name}</option>
          </select>
        </div>
        <input type="hidden" name="mine" value="false" />
        <input
          id="ideas-mine"
          type="checkbox"
          name="mine"
          value="true"
          checked={@mine}
          class="peer sr-only"
        />
        <label
          for="ideas-mine"
          class="badge badge-outline badge-sm h-7 text-xs cursor-pointer select-none px-3 peer-checked:badge-primary peer-focus-visible:outline peer-focus-visible:outline-2"
        >
          Mentioning me
        </label>
      </form>
      <div
        class="min-h-0 flex-1 overflow-y-auto pr-1"
        tabindex="0"
        aria-label={"#{Transitions.label(@column)} cards"}
      >
        <p :if={@cards == []} class="px-1 text-sm text-[var(--paper-muted)]">Nothing here yet.</p>
        <ul class="grid min-w-0 grid-cols-1 gap-1.5">
          <li
            :for={{idea, look} <- Enum.map(@cards, &{&1, look(&1, @founder)})}
            id={"tile-#{idea.id}"}
            draggable="true"
            data-board-card={idea.id}
            data-moves={Enum.join(look.moves, " ")}
            data-size="thin"
            data-faded={to_string(look.faded)}
            data-needs-work={to_string(look.needs_work)}
            class={[
              "card card-border min-w-0 rounded-lg bg-[var(--paper-panel)] px-2 py-1.5 text-sm hover:border-[var(--paper-accent)]",
              if(look.needs_work, do: "border-2 border-warning", else: "border-[var(--paper-rule)]"),
              look.faded && "opacity-50"
            ]}
          >
            <%!-- The open button and the vote row are siblings, so a vote
                 never opens the card. --%>
            <button
              type="button"
              phx-click={open_js(@myself, idea.id)}
              aria-haspopup="dialog"
              class="flex w-full min-w-0 min-h-11 flex-row items-center gap-2 text-left"
            >
              <.avatar id={idea.id} size="size-6" />
              <span class="min-w-0 flex-1">
                <span class="block break-words font-semibold leading-snug" data-role="title">
                  {idea.title}
                </span>
                <span
                  :if={look.blocker}
                  id={"tile-#{idea.id}-reason"}
                  data-role="reason"
                  class="block break-words text-xs leading-tight text-[var(--paper-muted)]"
                >
                  {look.blocker}
                </span>
              </span>
              <span
                :if={hint = Typing.hint(@typing[idea.id] || [], @founder)}
                id={"tile-#{idea.id}-typing"}
                class="shrink-0"
                role="img"
                aria-label={hint}
                title={hint}
              >
                <.icon name="hero-pencil-square" class="size-4 motion-safe:animate-pulse" />
              </span>
              <span
                :if={look.needs_work}
                class="badge badge-warning badge-xs shrink-0"
                title="Needs work: a founder voted -1"
              >
                Needs work
              </span>
              <span
                :if={n = Board.pr_number_of(idea)}
                id={"tile-#{idea.id}-pr"}
                class={["badge badge-xs shrink-0", elem(pr_status(@prs[n]), 1)]}
                aria-label={"PR #{n}, #{elem(pr_status(@prs[n]), 0)}"}
                title={"PR #{n}: #{elem(pr_status(@prs[n]), 0)}"}
              >
                #{n}
              </span>
            </button>
            <.tile_votes idea={idea} founder={@founder} myself={@myself} />
            <%!-- Siblings of the open button: answering a PR never opens the
                 card, except Request changes, which opens it for the comment. --%>
            <div
              :if={idea.column == "building" and Board.pr_waiting?(idea)}
              id={"tile-#{idea.id}-pr-waiting"}
              class="mt-1 flex flex-wrap items-center gap-1"
            >
              <span class="badge badge-info badge-xs">PR waiting for approval</span>
              <button
                type="button"
                id={"tile-#{idea.id}-approve"}
                phx-click="answer_pr"
                phx-value-card_id={idea.id}
                phx-value-answer="approve"
                phx-target={@myself}
                aria-label={"Approve PR ##{idea.pr_number} of #{idea.title}"}
                class="min-h-8 rounded-full border border-success px-2 text-xs font-semibold"
              >
                Approve
              </button>
              <button
                type="button"
                id={"tile-#{idea.id}-request-changes"}
                phx-click={
                  open_js(@myself, idea.id) |> JS.focus(to: "#card-#{idea.id}-answer textarea")
                }
                aria-label={"Request changes on PR ##{idea.pr_number} of #{idea.title}: opens the card for a comment"}
                class="min-h-8 rounded-full border px-2 text-xs"
              >
                Request changes
              </button>
            </div>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  attr :idea, :any, required: true
  attr :founder, :string, required: true
  attr :myself, :any, required: true

  # The vote row inside a thin card: thumbs up and thumbs down, each with its
  # own count. No net number on the card (sorting still uses net, then total).
  defp tile_votes(assigns) do
    ~H"""
    <.vote_buttons
      idea={@idea}
      founder={@founder}
      myself={@myself}
      prefix={"tile-#{@idea.id}"}
      class="mt-1 justify-end text-xs"
      button_class="min-h-6 px-1.5"
      icon_class="size-4"
    />
    """
  end

  attr :idea, :map, required: true
  attr :founder, :string, default: nil
  attr :myself, :any, required: true
  attr :prefix, :string, required: true
  attr :class, :string, default: nil
  attr :button_class, :string, default: nil
  attr :icon_class, :string, default: "size-5"
  attr :downvote_for, :any, default: :none

  # The two vote buttons, shared by thin and full cards: [thumb up] n
  # [thumb down] m. aria-label "Upvote: n" / "Downvote: m"; aria-pressed and
  # a filled highlight show the current founder's own vote. The buttons are
  # siblings of the card's open button, so a vote never opens the card.
  defp vote_buttons(assigns) do
    votes = assigns.idea.votes

    assigns =
      assign(assigns,
        up: Enum.count(votes, &(&1.value == 1)),
        down: Enum.count(votes, &(&1.value == -1)),
        mine: Board.vote_of(assigns.idea, assigns.founder)
      )

    ~H"""
    <div
      class={["flex items-center gap-1", @class]}
      role="group"
      aria-label={"Votes on #{@idea.title}"}
    >
      <button
        type="button"
        id={"#{@prefix}-up"}
        phx-click="vote"
        phx-value-card_id={@idea.id}
        phx-value-vote="1"
        phx-target={@myself}
        aria-pressed={to_string(@mine == 1)}
        aria-label={"Upvote: #{@up}"}
        title={if @mine == 1, do: "Your upvote. Click to take it back.", else: "Upvote"}
        data-mine={@mine == 1 && "true"}
        class={[
          "inline-flex items-center gap-1 rounded border leading-none",
          @button_class,
          if(@mine == 1,
            do:
              "border-[var(--paper-accent)] bg-[var(--paper-accent)] text-[var(--paper-on-accent)] font-semibold",
            else: "border-transparent hover:bg-[var(--paper-bg)]"
          )
        ]}
      >
        <.icon name="hero-hand-thumb-up" class={@icon_class} />
        <span data-role="up" class="tabular-nums" aria-hidden="true">{@up}</span>
      </button>
      <button
        type="button"
        id={"#{@prefix}-down"}
        phx-click="vote"
        phx-value-card_id={@idea.id}
        phx-value-vote="-1"
        phx-target={@myself}
        aria-pressed={to_string(@mine == -1)}
        aria-label={"Downvote: #{@down}"}
        title={
          if @mine == -1,
            do: "Your downvote. Click to take it back.",
            else: "Downvote (needs a reason)"
        }
        aria-expanded={@downvote_for != :none && to_string(@downvote_for == @idea.id)}
        aria-controls={@downvote_for != :none && "card-#{@idea.id}-downvote"}
        data-mine={@mine == -1 && "true"}
        class={[
          "inline-flex items-center gap-1 rounded border leading-none",
          @button_class,
          if(@mine == -1,
            do: "border-red-700 bg-red-700 text-white font-semibold",
            else: "border-transparent hover:bg-[var(--paper-bg)]"
          )
        ]}
      >
        <.icon name="hero-hand-thumb-down" class={@icon_class} />
        <span data-role="down" class="tabular-nums" aria-hidden="true">{@down}</span>
      </button>
    </div>
    """
  end

  defp comment_prompt(_from, "refining"), do: "What must change? (necessary)"
  defp comment_prompt(_from, _to), do: "Comment for the move log"

  attr :idea, :any, required: true
  attr :founder, :string, required: true
  attr :myself, :any, required: true
  attr :drafts, :map, default: %{}

  # Case's open questions, in any column: each has a text box and a Defer
  # toggle (Defer disables the box). The boxes save together with the next
  # move, when the card closes, and on blur. Another founder's answer is
  # read-only.
  defp questions(assigns) do
    items =
      for {{q, a}, i} <- Enum.with_index(Board.questions(assigns.idea)) do
        d = Map.get(assigns.drafts, {assigns.idea.id, q}, %{})

        %{
          q: q,
          a: a,
          i: i,
          theirs?: !!(a && a.answered_by not in [nil, assigns.founder]),
          text: Map.get(d, "answer", a && a.answered_by == assigns.founder && a.answer) || "",
          deferred: Map.get(d, "deferred", (a && a.deferred) || false)
        }
      end

    assigns =
      assign(assigns,
        items: items,
        open: draft_facts(assigns.idea, assigns.drafts, assigns.founder).open_questions
      )

    ~H"""
    <section
      :if={@items != []}
      id={"card-#{@idea.id}-questions"}
      aria-labelledby={"card-#{@idea.id}-questions-title"}
      class="space-y-2"
    >
      <h5 id={"card-#{@idea.id}-questions-title"} class="font-semibold">
        Open questions
        <span class="badge badge-sm ml-1" data-role="open-count">
          {if @open == 0, do: "all settled", else: "#{@open} open"}
        </span>
      </h5>
      <p class="text-xs text-[var(--paper-muted)]">
        Your answers save when you move or close the card.
      </p>
      <form
        id={"card-#{@idea.id}-answers"}
        phx-change="draft_answers"
        phx-submit="save_answers"
        phx-target={@myself}
      >
        <input type="hidden" name="card_id" value={@idea.id} />
        <ol class="space-y-2">
          <li
            :for={it <- @items}
            id={"card-#{@idea.id}-q#{it.i}"}
            data-state={draft_state(it)}
            class={[
              "rounded-lg border p-2",
              if(draft_state(it) == "open", do: "border-warning", else: "border-[var(--paper-rule)]")
            ]}
          >
            <p id={"card-#{@idea.id}-q#{it.i}-text"} class="font-semibold">{it.q}</p>
            <input type="hidden" name={"questions[#{it.i}]"} value={it.q} />
            <p :if={it.a && it.a.answer} class="mt-1" data-role="answer">
              <span class="badge badge-success badge-xs">Answered</span>
              {it.a.answer}
              <span class="text-xs text-[var(--paper-muted)]">
                by {who(it.a.answered_by)},
                <time datetime={DateTime.to_iso8601(it.a.answered_at)}>{TalesForgeWeb.TimeAgo.stockholm(
                  it.a.answered_at
                )}</time>
              </span>
            </p>
            <p :if={it.a && it.a.deferred} class="mt-1 text-xs" data-role="deferred">
              <span class="badge badge-ghost badge-xs">Deferred</span> by {who(it.a.deferred_by)}
            </p>
            <div class="mt-1 grid gap-1 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-start">
              <div :if={!it.theirs?} class="min-w-0">
                <label class="sr-only" for={"card-#{@idea.id}-q#{it.i}-answer"}>
                  Your answer to: {it.q}
                </label>
                <textarea
                  id={"card-#{@idea.id}-q#{it.i}-answer"}
                  name={"answers[#{it.i}]"}
                  rows="2"
                  disabled={it.deferred}
                  phx-blur="save_answers"
                  phx-value-card_id={@idea.id}
                  phx-target={@myself}
                  aria-describedby={"card-#{@idea.id}-q#{it.i}-text"}
                  placeholder={if it.deferred, do: "Deferred", else: "Your answer"}
                  class="w-full rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-2 py-1 disabled:opacity-60"
                >{it.text}</textarea>
              </div>
              <button
                type="button"
                id={"card-#{@idea.id}-q#{it.i}-defer"}
                phx-click="toggle_defer"
                phx-value-card_id={@idea.id}
                phx-value-question={it.q}
                phx-value-deferred={to_string(!it.deferred)}
                phx-target={@myself}
                aria-pressed={to_string(it.deferred)}
                aria-describedby={"card-#{@idea.id}-q#{it.i}-text"}
                class={[
                  "min-h-11 rounded border px-3 text-xs",
                  it.deferred && "bg-[var(--paper-margin)] font-semibold"
                ]}
              >
                {if it.deferred, do: "Deferred", else: "Defer"}
              </button>
            </div>
          </li>
        </ol>
      </form>
    </section>
    """
  end

  defp draft_state(it) do
    cond do
      it.deferred -> "deferred"
      it.theirs? or String.trim(it.text) != "" -> "answered"
      true -> "open"
    end
  end

  # Board.facts/1 with the founder's unsaved answer boxes: the buttons and the
  # gate use what is on the screen now. The server checks again on the move.
  defp draft_facts(idea, drafts, founder) do
    facts = Board.facts(idea)

    if Enum.any?(drafts, fn {{id, _}, _} -> id == idea.id end) do
      open =
        Enum.count(Board.questions(idea), fn {q, a} ->
          d = Map.get(drafts, {idea.id, q}, %{})
          deferred = Map.get(d, "deferred", (a && a.deferred) || false)
          theirs? = !!(a && a.answered_by not in [nil, founder])
          text = Map.get(d, "answer", (a && a.answered_by == founder && a.answer) || "")
          not (deferred or theirs? or String.trim(to_string(text)) != "")
        end)

      %{facts | open_questions: open}
    else
      facts
    end
  end

  # The PR feed's pull requests by number (TalesForge.PrFeed: title, state,
  # and whether production runs the merge, from /internal/version).
  defp prs do
    Map.new(TalesForge.PrFeed.snapshot().items, &{&1.number, &1})
  rescue
    _ -> %{}
  end

  defp pr_of_link(%{url: url}) do
    case Regex.run(~r{/pull/(\d+)}, url) do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  @doc """
  The status of a PR from the PR feed (`nil` when the feed has no such PR),
  with its badge colour.

      iex> TalesForgeWeb.TeamIdeaBoard.pr_status(%{state: :open})
      {"open", "badge-info"}
      iex> TalesForgeWeb.TeamIdeaBoard.pr_status(%{state: :merged, deployed: %{production: :deployed}})
      {"on prod", "badge-success"}
      iex> TalesForgeWeb.TeamIdeaBoard.pr_status(%{state: :merged, deployed: %{production: :pending}})
      {"merged", "badge-primary"}
      iex> TalesForgeWeb.TeamIdeaBoard.pr_status(%{state: :closed})
      {"closed", "badge-ghost"}
      iex> TalesForgeWeb.TeamIdeaBoard.pr_status(nil)
      {"status unknown", "badge-ghost"}
  """
  @spec pr_status(map() | nil) :: {String.t(), String.t()}
  def pr_status(%{state: :merged, deployed: %{production: :deployed}}),
    do: {"on prod", "badge-success"}

  def pr_status(%{state: :merged}), do: {"merged", "badge-primary"}
  def pr_status(%{state: :open}), do: {"open", "badge-info"}
  def pr_status(%{state: _}), do: {"closed", "badge-ghost"}
  def pr_status(_), do: {"status unknown", "badge-ghost"}

  # How a tile looks and where it may go: faded with no votes (in Ideas), a
  # "needs work" border with a downvote, the reason it cannot take its next
  # step, and the columns the founder may drop it on (all from
  # TalesForge.Board.Transitions).
  defp look(idea, founder) do
    facts = Board.facts(idea)

    %{
      faded: idea.column == "ideas" and idea.votes == [],
      needs_work: facts.down > 0,
      blocker: Transitions.blocker(facts, idea.column),
      moves:
        for({to, :ok} <- Transitions.options(facts, idea.column, {:founder, founder}), do: to)
    }
  end

  attr :id, :string, required: true
  attr :size, :string, default: "size-8"

  @doc false
  def avatar(assigns) do
    assigns = assign(assigns, :a, avatar_spec(assigns.id))

    ~H"""
    <span class="avatar shrink-0"><svg
      viewBox="0 0 5 5"
      class={["shrink-0 rounded", @size]}
      aria-hidden="true"
      data-avatar={@a.hue}
      style={"background:hsl(#{@a.hue} 45% 92%)"}
    >
      <rect
        :for={{x, y} <- @a.cells}
        x={x}
        y={y}
        width="1"
        height="1"
        fill={"hsl(#{@a.hue} 55% 42%)"}
      />
    </svg></span>
    """
  end

  @doc """
  The card's avatar: a mirrored 5×5 identicon and a hue, both from a hash of
  the card id, so a card always looks the same.

      iex> a = TalesForgeWeb.TeamIdeaBoard.avatar_spec("0ab31ff4-c605-4aa2-8a65-e067dc23649c")
      iex> a == TalesForgeWeb.TeamIdeaBoard.avatar_spec("0ab31ff4-c605-4aa2-8a65-e067dc23649c")
      true
      iex> a.hue in 0..359 and Enum.all?(a.cells, fn {x, y} -> {4 - x, y} in a.cells end)
      true
  """
  @spec avatar_spec(String.t()) :: %{hue: 0..359, cells: [{0..4, 0..4}]}
  def avatar_spec(id) do
    <<h::16, bits::15, _::bitstring>> = :crypto.hash(:sha256, id)

    cells =
      for x <- 0..2,
          y <- 0..4,
          Bitwise.band(Bitwise.bsr(bits, x * 5 + y), 1) == 1,
          cx <- Enum.uniq([x, 4 - x]),
          do: {cx, y}

    %{hue: rem(h, 360), cells: cells}
  end

  attr :idea, :any, required: true
  attr :founder, :string, required: true
  attr :myself, :any, required: true
  attr :error, :string, default: nil
  attr :prs, :map, default: %{}
  attr :comment_for, :any, default: nil
  attr :downvote_for, :any, default: nil
  attr :editing, :any, default: nil
  attr :drafts, :map, default: %{}
  attr :typing, :map, default: %{}
  attr :uploads, :map, default: nil

  defp card(assigns) do
    idea = assigns.idea

    assigns =
      assign(assigns,
        facts: draft_facts(idea, assigns.drafts, assigns.founder),
        buttons:
          Transitions.buttons(
            draft_facts(idea, assigns.drafts, assigns.founder),
            idea.column,
            {:founder, assigns.founder}
          ),
        downvotes: Enum.filter(idea.votes, &(&1.value == -1)),
        comment_to:
          case assigns.comment_for do
            {id, to} when id == idea.id -> to
            _ -> nil
          end,
        r: idea.refinement || %{}
      )

    ~H"""
    <article
      id={"card-#{@idea.id}"}
      class="space-y-3 text-sm"
    >
      <div class="flex items-start gap-3">
        <.avatar id={@idea.id} size="size-10" />
        <div class="min-w-0 flex-1">
          <h2 id="board-modal-title" class="font-serif text-xl font-bold leading-snug">
            {@idea.title}
          </h2>
          <p class="text-xs text-[var(--paper-muted)]">
            by {who(@idea.author)}<span :if={@idea.column == "ideas"}> · score {:erlang.float_to_binary(
              @idea.score || 0.0,
              decimals: 2
            )}</span>
          </p>
          <p class="mt-1 flex flex-wrap gap-1">
            <span
              :if={@facts.down > 0}
              id={"card-#{@idea.id}-blocked"}
              class="badge badge-warning badge-sm"
            >
              Needs work
            </span>
            <span
              :if={Transitions.blocker(@facts, @idea.column)}
              id={"card-#{@idea.id}-reason"}
              class="badge badge-ghost badge-sm h-auto"
            >
              {Transitions.blocker(@facts, @idea.column)}
            </span>
            <span :if={@idea.decision_sha} class="badge badge-ghost badge-sm">Decision logged</span>
          </p>
          <ul
            :if={@downvotes != []}
            id={"card-#{@idea.id}-downvote-reasons"}
            class="mt-1 space-y-0.5 text-xs"
            aria-label="Why it needs work"
          >
            <li :for={v <- @downvotes}>
              <span class="font-semibold">{who(v.founder)}:</span> {v.reason}
            </li>
          </ul>
        </div>
        <.vote_buttons
          idea={@idea}
          founder={@founder}
          myself={@myself}
          prefix={"card-#{@idea.id}"}
          class="shrink-0"
          button_class="min-h-11 min-w-11 justify-center px-2"
          downvote_for={@downvote_for}
        />
      </div>

      <form
        :if={@downvote_for == @idea.id}
        id={"card-#{@idea.id}-downvote"}
        phx-submit="downvote"
        phx-target={@myself}
        class="grid gap-1 rounded-lg border-2 border-warning p-2"
      >
        <input type="hidden" name="card_id" value={@idea.id} />
        <label class="grid gap-1 font-semibold">
          What needs work? (necessary for a -1) <textarea
            id={"card-#{@idea.id}-downvote-reason"}
            name="reason"
            rows="2"
            required
            phx-mounted={JS.focus()}
            class="rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-2 py-1 font-normal"
          ></textarea>
        </label>
        <div class="flex flex-wrap gap-2">
          <button type="submit" class="min-h-11 rounded border px-3 font-semibold">Save -1 and reason</button>
          <button
            type="button"
            phx-click="cancel_downvote"
            phx-target={@myself}
            class="min-h-11 rounded px-3"
          >
            Cancel
          </button>
        </div>
      </form>

      <p
        :if={@error}
        id={"card-#{@idea.id}-error"}
        role="alert"
        class="mt-2 rounded bg-red-50 px-2 py-1 text-red-800"
      >
        {@error}
      </p>

      <div class="space-y-3 pt-1">
        <p :if={@idea.body != ""} class="whitespace-pre-line">{@idea.body}</p>

        <div
          :if={@buttons != []}
          id={"card-#{@idea.id}-moves"}
          role="group"
          aria-label="Move the card"
          class="space-y-1"
        >
          <div class="flex flex-wrap gap-2">
            <button
              :for={b <- @buttons}
              type="button"
              id={"card-#{@idea.id}-#{b.kind}"}
              phx-click="step"
              phx-value-card_id={@idea.id}
              phx-value-to={b.to}
              phx-value-needs_comment={to_string(b.needs_comment)}
              phx-target={@myself}
              disabled={b.answer != :ok}
              aria-describedby={b.answer != :ok && "card-#{@idea.id}-#{b.kind}-why"}
              aria-expanded={b.needs_comment && to_string(@comment_to == b.to)}
              class={[
                "min-h-11 rounded-full border px-4 font-semibold disabled:cursor-not-allowed disabled:opacity-50",
                b.kind == :forward && "team-cta"
              ]}
            >
              {b.label}
            </button>
          </div>
          <p
            :for={b <- @buttons}
            :if={b.answer != :ok}
            id={"card-#{@idea.id}-#{b.kind}-why"}
            class="text-xs text-[var(--paper-muted)]"
          >
            {b.label}: {elem(b.answer, 1)}
          </p>
          <form
            :if={@comment_to}
            id={"card-#{@idea.id}-move"}
            phx-submit="move"
            phx-target={@myself}
            class="grid gap-1"
          >
            <input type="hidden" name="card_id" value={@idea.id} />
            <input type="hidden" name="to" value={@comment_to} />
            <label class="grid gap-1 font-semibold">
              {comment_prompt(@idea.column, @comment_to)}
              <textarea
                id={"card-#{@idea.id}-move-note"}
                name="note"
                rows="2"
                required
                phx-mounted={JS.focus()}
                class="rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-2 py-1 font-normal"
              ></textarea>
            </label>
            <div class="flex flex-wrap gap-2">
              <button type="submit" class="min-h-11 rounded border px-3 font-semibold">
                Move to {Transitions.label(@comment_to)}
              </button>
              <button
                type="button"
                phx-click="cancel_comment"
                phx-target={@myself}
                class="min-h-11 rounded px-3"
              >
                Cancel
              </button>
            </div>
          </form>
        </div>

        <section
          :if={@idea.pr_number}
          id={"card-#{@idea.id}-pr"}
          aria-labelledby={"card-#{@idea.id}-pr-title"}
          class="space-y-2 rounded-lg border border-[var(--paper-accent)] p-3"
        >
          <h5 id={"card-#{@idea.id}-pr-title"} class="font-semibold">
            Merge approval:
            <a
              href={@idea.pr_url}
              class="text-[var(--paper-accent)] underline"
              rel="noopener noreferrer"
            >PR #{@idea.pr_number}</a>
            <span class="font-mono text-xs text-[var(--paper-muted)]">{String.slice(
              @idea.pr_head_sha || "",
              0,
              7
            )}</span>
          </h5>
          <p :if={@idea.player_note} data-role="player-note">
            <span class="font-semibold">For players:</span> {@idea.player_note}
          </p>
          <p :if={@facts.pr == :awaiting} class="badge badge-info" data-role="pr-waiting">
            PR waiting for approval
          </p>
          <form
            :if={@facts.pr == :awaiting and @idea.column == "building"}
            id={"card-#{@idea.id}-answer"}
            phx-submit="answer_pr"
            phx-target={@myself}
            class="grid gap-1"
          >
            <input type="hidden" name="card_id" value={@idea.id} />
            <label class="grid gap-1">
              Comment for Bobby (optional) <textarea
                name="comment"
                rows="2"
                class="rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-2 py-1"
              ></textarea>
            </label>
            <div class="flex flex-wrap gap-2">
              <button
                type="submit"
                name="answer"
                value="approve"
                aria-label={"Approve PR ##{@idea.pr_number} for merge"}
                class="team-cta min-h-11 rounded-full px-4 font-semibold"
              >Approve</button>
              <button
                type="submit"
                name="answer"
                value="request_changes"
                aria-label={"Request changes on PR ##{@idea.pr_number}"}
                class="min-h-11 rounded-full border px-4 font-semibold"
              >Request changes</button>
            </div>
          </form>
          <ol
            :if={@idea.approvals != []}
            id={"card-#{@idea.id}-approvals"}
            class="space-y-0.5 text-xs"
            aria-label="Approval log"
          >
            <li :for={a <- @idea.approvals}>
              {if a.decision == "approved", do: "✓ Approved", else: "↺ Changes requested"} by {who(
                a.founder
              )} · PR #{a.pr_number}
              <span class="font-mono">{String.slice(a.head_sha || "", 0, 7)}</span>
              ·
              <time datetime={DateTime.to_iso8601(a.inserted_at)}>{TalesForgeWeb.TimeAgo.stockholm(
                a.inserted_at
              )}</time>
              <span :if={a.comment not in [nil, ""]}>: {a.comment}</span>
            </li>
          </ol>
        </section>

        <.questions idea={@idea} founder={@founder} myself={@myself} drafts={@drafts} />

        <section aria-label="Case's refinement" class="space-y-1">
          <div class="flex items-center justify-between gap-2">
            <h5 class="font-semibold">Case's refinement</h5>
            <button
              :if={@idea.column == "refining" and @editing != @idea.id}
              type="button"
              id={"card-#{@idea.id}-edit-refinement"}
              phx-click="edit_refinement"
              phx-value-card_id={@idea.id}
              phx-target={@myself}
              aria-label="Edit Case's refinement"
              class="min-h-11 rounded border px-3 text-xs font-semibold"
            >
              Edit
            </button>
          </div>
          <p :if={@r == %{}} class="text-xs text-[var(--paper-muted)]">
            Case has not written it yet.
          </p>
          <dl
            :if={@r != %{} and @editing != @idea.id}
            id={"card-#{@idea.id}-refinement"}
            class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-2 text-xs"
          >
            <dt>Details</dt><dd class="whitespace-pre-line">{@r["details"] || "-"}</dd>
            <dt>Open questions</dt><dd>
              {Enum.join(@r["open_questions"] || [], " · ") |> blank("-")}
            </dd>
            <dt>Rough cost</dt><dd>{@r["rough_cost"] || "-"}</dd>
            <dt>Verdict</dt><dd>{(@r["verdict"] || "-") |> String.replace("_", " ")}</dd>
          </dl>
          <form
            :if={@idea.column == "refining" and @editing == @idea.id}
            phx-submit="refine"
            phx-target={@myself}
            class="grid gap-1"
            id={"card-#{@idea.id}-refine"}
          >
            <input type="hidden" name="card_id" value={@idea.id} />
            <label class="grid gap-1">
              Details <textarea
                name="details"
                rows="3"
                class="rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-2 py-1"
              >{@r["details"]}</textarea>
            </label>
            <label class="grid gap-1">
              Open questions (one per line) <textarea
                name="open_questions"
                rows="2"
                class="rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-2 py-1"
              >{Enum.join(@r["open_questions"] || [], "\n")}</textarea>
            </label>
            <div class="grid grid-cols-2 gap-2">
              <label class="grid gap-1">
                Rough cost
                <select
                  name="rough_cost"
                  class="min-h-11 rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-2"
                >
                  <option value="">-</option>
                  <option :for={c <- ~w(S M L)} value={c} selected={@r["rough_cost"] == c}>
                    {c}
                  </option>
                </select>
              </label>
              <label class="grid gap-1">
                Verdict
                <select
                  name="verdict"
                  class="min-h-11 rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-2"
                >
                  <option value="">-</option>
                  <option
                    :for={v <- ~w(feasible feasible_with_caveats not_feasible)}
                    value={v}
                    selected={@r["verdict"] == v}
                  >
                    {String.replace(v, "_", " ")}
                  </option>
                </select>
              </label>
            </div>
            <div class="flex flex-wrap gap-2">
              <button type="submit" class="min-h-11 rounded border px-3 font-semibold">Save refinement</button>
              <button
                type="button"
                phx-click="cancel_refinement"
                phx-target={@myself}
                class="min-h-11 rounded px-3"
              >
                Cancel
              </button>
            </div>
          </form>
        </section>

        <section aria-label="Links" class="space-y-1">
          <h5 class="font-semibold">Links</h5>
          <p :if={@idea.links == []} class="text-xs text-[var(--paper-muted)]">
            No links yet. Bobby and Gentry add the PR and the playtest run.
          </p>
          <ul id={"card-#{@idea.id}-links"} class="space-y-0.5">
            <li :for={l <- @idea.links} data-kind={l.kind}>
              <%= case {l.kind, pr_of_link(l)} do %>
                <% {"pr", n} when is_integer(n) -> %>
                  <% {status, colour} = pr_status(@prs[n]) %>
                  <a
                    href={l.url}
                    class="text-[var(--paper-accent)] underline"
                    rel="noopener noreferrer"
                  >
                    PR #{n}
                  </a>
                  <span>{(@prs[n] && @prs[n].title) || l.label}</span>
                  <span class={["badge badge-sm", colour]} data-role="pr-status">{status}</span>
                <% {"playtest", _} -> %>
                  <a
                    href={l.url}
                    class="text-[var(--paper-accent)] underline"
                    rel="noopener noreferrer"
                  >
                    Playtest run{if l.label, do: ": " <> l.label}
                  </a>
                <% _ -> %>
                  <span class="text-xs uppercase text-[var(--paper-muted)]">{l.kind}</span>
                  <a
                    href={l.url}
                    class="break-all text-[var(--paper-accent)] underline"
                    rel="noopener noreferrer"
                  >{l.label || l.url}</a>
              <% end %>
            </li>
          </ul>
        </section>

        <.card_images :if={@uploads} idea={@idea} upload={@uploads.card_images} myself={@myself} />

        <section aria-label="Comments" class="space-y-1">
          <h5 class="font-semibold">Comments</h5>
          <ul class="space-y-1">
            <li
              :for={c <- @idea.comments}
              id={"comment-#{c.id}"}
              class="rounded bg-[var(--paper-margin)] px-2 py-1 leading-snug"
            >
              <div class="flex items-baseline gap-2 text-xs">
                <span class="font-semibold">{who(c.author)}</span>
                <time
                  datetime={DateTime.to_iso8601(c.inserted_at)}
                  class="text-[var(--paper-muted)]"
                >{TalesForgeWeb.TimeAgo.stockholm(c.inserted_at)}</time>
              </div>
              <p class="whitespace-pre-line break-words">{comment_body(c.body)}</p>
            </li>
          </ul>
          <form
            phx-submit="comment"
            phx-change="typing"
            phx-target={@myself}
            class="grid gap-1"
            id={"card-#{@idea.id}-comment"}
          >
            <input type="hidden" name="card_id" value={@idea.id} />
            <label class="grid gap-1" for={"card-#{@idea.id}-comment-body"}>
              Comment. Write @ and a name to ping a founder, or @founders to ping all founders. @case, @bobby or @gentry wakes that bot.
            </label>
            <div class="relative">
              <textarea
                id={"card-#{@idea.id}-comment-body"}
                name="body"
                rows="2"
                required
                phx-hook="MentionSuggest"
                data-handles={Jason.encode!(Mentions.suggestions())}
                aria-autocomplete="list"
                aria-controls={"card-#{@idea.id}-mention-list"}
                aria-describedby={"card-#{@idea.id}-typing"}
                phx-throttle="1000"
                class="w-full rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-2 py-1"
              ></textarea>
              <ul
                id={"card-#{@idea.id}-mention-list"}
                role="listbox"
                aria-label="Names to mention"
                phx-update="ignore"
                hidden
                class="absolute z-10 mt-1 rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] text-sm shadow"
              >
              </ul>
            </div>
            <p
              id={"card-#{@idea.id}-typing"}
              aria-live="polite"
              class="min-h-5 text-xs italic text-[var(--paper-muted)]"
            >
              {Typing.hint(@typing[@idea.id] || [], @founder)}
            </p>
            <button type="submit" class="min-h-11 rounded border px-3">Comment</button>
          </form>
        </section>

        <section aria-label="History" class="text-xs text-[var(--paper-muted)]">
          <h5 class="font-semibold">History</h5>
          <ol>
            <li :for={t <- @idea.transitions}>
              {if t.from, do: Transitions.label(t.from) <> " → ", else: "Added to "}{Transitions.label(
                t.to
              )} by {who(t.actor)}<span :if={t.note}>: {t.note}</span>
            </li>
          </ol>
        </section>
      </div>
    </article>
    """
  end

  attr :idea, :any, required: true
  attr :upload, :any, required: true
  attr :myself, :any, required: true

  # The card's images and the form that adds more. A card in Done has no
  # images: they go when it reaches Done.
  defp card_images(assigns) do
    assigns = assign(assigns, :images, images(assigns.idea))

    ~H"""
    <section id={"card-#{@idea.id}-images"} aria-label="Images" class="space-y-1">
      <h5 class="font-semibold">Images</h5>
      <TeamImages.thumbnails images={@images} id={"card-#{@idea.id}-thumbs"} />
      <form
        :if={@idea.column != "done"}
        id={"card-#{@idea.id}-image-form"}
        phx-submit="add_images"
        phx-change="validate_images"
        phx-target={@myself}
        phx-drop-target={@upload.ref}
        phx-hook="ImageInput"
        class="grid gap-2 rounded border border-dashed border-[var(--paper-rule)] p-2"
      >
        <input type="hidden" name="card_id" value={@idea.id} />
        <TeamImages.picker upload={@upload} id={"card-#{@idea.id}-picker"} target={@myself} />
        <label class="grid gap-1" for={"card-#{@idea.id}-image-note"}>
          Note (optional). Paste or drop an image here, too.
          <input
            id={"card-#{@idea.id}-image-note"}
            type="text"
            name="note"
            maxlength="2000"
            class="w-full rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-2 py-1"
          />
        </label>
        <button
          type="submit"
          disabled={@upload.entries == []}
          class="min-h-11 justify-self-start rounded border px-3 disabled:opacity-50"
        >
          Add to card
        </button>
      </form>
    </section>
    """
  end

  defp images(%Idea{images: images}) when is_list(images), do: images
  defp images(_idea), do: []

  defp who("bot:" <> bot), do: String.capitalize(bot)
  defp who(email) when is_binary(email), do: TalesForge.TeamOnline.name(email)
  defp who(_), do: "someone"

  # A comment body as one line of HTML: the text is escaped, the mentions are
  # inline marks, the author's own line breaks stay (whitespace-pre-line),
  # and the edges are trimmed.
  defp comment_body(body) do
    (body || "")
    |> String.trim()
    |> Mentions.segments()
    |> Enum.map(fn
      {:mention, s} ->
        [
          ~s(<mark class="rounded px-0.5 font-semibold text-[var\(--paper-accent\)] bg-transparent">),
          Phoenix.HTML.html_escape(s) |> Phoenix.HTML.safe_to_string(),
          "</mark>"
        ]

      {_, s} ->
        Phoenix.HTML.html_escape(s) |> Phoenix.HTML.safe_to_string()
    end)
    |> IO.iodata_to_binary()
    |> Phoenix.HTML.raw()
  end

  defp blank("", default), do: default
  defp blank(s, _), do: s
end
