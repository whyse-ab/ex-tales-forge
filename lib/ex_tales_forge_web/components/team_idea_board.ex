defmodule TalesForgeWeb.TeamIdeaBoard do
  @moduledoc """
  The founders' idea board on /team (`#idea-board`; design: tales-forge-docs
  `docs/design-idea-board.md`). A LiveComponent over `TalesForge.Board`:
  add ideas, vote +1/-1 (again to take it back), comment (with `@case`,
  `@bobby`, `@gentry` to wake a bot), add links, fill in Case's refinement,
  and move cards.

  Moving: drag a card onto a column (the `TeamPage` hook, `assets/js/team_hooks.js`),
  or, with a keyboard or on a phone, the card's "Move to" form, which lists only
  the moves `TalesForge.Board.Rules` allows a founder. The rules are checked
  again on every move; a refusal (for example the open -1 block on Building)
  shows as a message on the card.

  Phone first: columns stack, each card opens in place (`<details>`). The
  parent LiveView forwards `{:board, :changed}` as `send_update(refresh: true)`.
  """
  use TalesForgeWeb, :live_component

  alias TalesForge.Board
  alias TalesForge.Board.{Idea, Link, Rules}

  @impl true
  def update(%{refresh: true}, socket), do: {:ok, load(socket)}

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:errors, fn -> %{} end)
     |> assign_new(:form_error, fn -> nil end)
     |> load()}
  end

  defp load(socket) do
    assign(socket,
      board: Board.board(),
      pullable: Board.pullable_ids()
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

  defp with_idea(socket, id, fun) do
    case Board.get_idea(id) do
      %Idea{} = idea -> result(socket, id, fun.(idea))
      nil -> result(socket, id, {:error, "That card is gone."})
    end
  end

  @impl true
  def handle_event("add", %{"idea" => attrs}, socket) do
    case Board.create_idea(socket.assigns.founder, attrs) do
      {:ok, _} -> {:noreply, socket |> assign(:form_error, nil) |> load()}
      {:error, cs} -> {:noreply, assign(socket, :form_error, changeset_text(cs))}
    end
  end

  def handle_event("vote", %{"card_id" => id, "value" => value}, socket),
    do: with_idea(socket, id, &Board.vote(&1, socket.assigns.founder, String.to_integer(value)))

  def handle_event("move", %{"card_id" => id, "to" => to} = params, socket) do
    note = params["note"] |> to_string() |> String.trim()
    with_idea(socket, id, &Board.move(&1, actor(socket), to, if(note == "", do: nil, else: note)))
  end

  def handle_event("comment", %{"card_id" => id, "body" => body}, socket),
    do: with_idea(socket, id, &Board.add_comment(&1, socket.assigns.founder, body))

  def handle_event("link", %{"card_id" => id} = params, socket),
    do:
      with_idea(
        socket,
        id,
        &Board.add_link(&1, socket.assigns.founder, Map.take(params, ~w(kind url label)))
      )

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
    with_idea(socket, id, &Board.refine(&1, attrs))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="team-idea-board space-y-5" data-board-target={"##{@id}"}>
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

      <div id="board-columns" class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
        <section
          :for={column <- Idea.columns()}
          id={"board-col-#{column}"}
          data-board-column={column}
          aria-labelledby={"board-col-#{column}-title"}
          class="team-board-column min-w-0 [&.is-drop-target]:ring-2 [&.is-drop-target]:ring-[var(--paper-accent)] space-y-2 rounded-xl border border-[var(--paper-rule)] bg-[var(--paper-margin)] p-3"
        >
          <h3
            id={"board-col-#{column}-title"}
            class="flex items-baseline justify-between font-serif text-lg font-bold"
          >
            {Rules.label(column)}
            <span class="font-sans text-xs font-normal text-[var(--paper-muted)]">
              {length(@board[column])} {if length(@board[column]) == 1, do: "card", else: "cards"}
            </span>
          </h3>
          <p :if={@board[column] == []} class="text-sm text-[var(--paper-muted)]">
            Nothing here yet.
          </p>
          <ul class="space-y-2">
            <li :for={idea <- @board[column]}>
              <.card
                idea={idea}
                founder={@founder}
                myself={@myself}
                pullable={MapSet.member?(@pullable, idea.id)}
                error={@errors[idea.id]}
              />
            </li>
          </ul>
        </section>
      </div>
    </div>
    """
  end

  attr :idea, :any, required: true
  attr :founder, :string, required: true
  attr :myself, :any, required: true
  attr :pullable, :boolean, default: false
  attr :error, :string, default: nil

  defp card(assigns) do
    idea = assigns.idea

    assigns =
      assign(assigns,
        net: Board.net_votes(idea),
        mine: Board.vote_of(idea, assigns.founder),
        blocked: Board.downvoted?(idea),
        targets: Rules.targets({:founder, assigns.founder}, idea.column),
        r: idea.refinement || %{}
      )

    ~H"""
    <article
      id={"card-#{@idea.id}"}
      draggable="true"
      data-board-card={@idea.id}
      aria-labelledby={"card-#{@idea.id}-title"}
      class="team-card rounded-lg bg-[var(--paper-panel)] p-3 text-sm"
    >
      <div class="flex items-start gap-2">
        <div class="min-w-0 flex-1">
          <h4 id={"card-#{@idea.id}-title"} class="font-semibold leading-snug">{@idea.title}</h4>
          <p class="text-xs text-[var(--paper-muted)]">
            by {who(@idea.author)}<span :if={@idea.column == "ideas"}> · score {:erlang.float_to_binary(
              @idea.score || 0.0,
              decimals: 2
            )}</span>
          </p>
          <p class="mt-1 flex flex-wrap gap-1">
            <span
              :if={@blocked}
              id={"card-#{@idea.id}-blocked"}
              class="team-badge rounded bg-red-100 px-1.5 text-xs text-red-800"
            >
              Open -1: talk it through before Building
            </span>
            <span :if={@pullable} class="team-badge rounded bg-[var(--paper-bg)] px-1.5 text-xs">Case may pull</span>
            <span
              :if={@idea.decision_sha}
              class="team-badge rounded bg-[var(--paper-bg)] px-1.5 text-xs"
            >Decision logged</span>
          </p>
        </div>
        <div
          class="flex shrink-0 items-center gap-1"
          role="group"
          aria-label={"Vote on #{@idea.title}"}
        >
          <button
            type="button"
            phx-click="vote"
            phx-value-card_id={@idea.id}
            phx-value-value="1"
            phx-target={@myself}
            aria-pressed={to_string(@mine == 1)}
            aria-label={if @mine == 1, do: "Take back your +1", else: "Vote +1"}
            class={[
              "min-h-11 min-w-11 rounded border px-2",
              @mine == 1 && "bg-[var(--paper-accent)] text-[var(--paper-on-accent)]"
            ]}
          >+1</button>
          <span class="min-w-6 text-center font-semibold" aria-label={"Net votes #{@net}"}>{@net}</span>
          <button
            type="button"
            phx-click="vote"
            phx-value-card_id={@idea.id}
            phx-value-value="-1"
            phx-target={@myself}
            aria-pressed={to_string(@mine == -1)}
            aria-label={if @mine == -1, do: "Take back your -1", else: "Vote -1"}
            class={["min-h-11 min-w-11 rounded border px-2", @mine == -1 && "bg-red-700 text-white"]}
          >-1</button>
        </div>
      </div>

      <p
        :if={@error}
        id={"card-#{@idea.id}-error"}
        role="alert"
        class="mt-2 rounded bg-red-50 px-2 py-1 text-red-800"
      >
        {@error}
      </p>

      <details class="mt-2" id={"card-#{@idea.id}-more"}>
        <summary class="min-h-11 cursor-pointer py-2 font-semibold text-[var(--paper-accent)]">
          Open card<span class="sr-only">: {@idea.title}</span>
          <span class="font-normal text-[var(--paper-muted)]">
            · {length(@idea.comments)} comments · {length(@idea.links)} links
          </span>
        </summary>
        <div class="space-y-3 pt-1">
          <p :if={@idea.body != ""} class="whitespace-pre-line">{@idea.body}</p>

          <form
            :if={@targets != []}
            phx-submit="move"
            phx-target={@myself}
            class="grid gap-1"
            id={"card-#{@idea.id}-move"}
          >
            <input type="hidden" name="card_id" value={@idea.id} />
            <label class="grid gap-1 font-semibold">
              Move to
              <select
                name="to"
                class="min-h-11 rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-2"
              >
                <option :for={t <- @targets} value={t}>{Rules.label(t)}</option>
              </select>
            </label>
            <input
              name="note"
              placeholder="Note for the history (optional)"
              aria-label="Note for the history"
              class="rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-2 py-1.5"
            />
            <button type="submit" class="min-h-11 rounded border px-3 font-semibold">Move</button>
          </form>

          <section aria-label="Case's refinement" class="space-y-1">
            <h5 class="font-semibold">Case's refinement</h5>
            <dl :if={@r != %{}} class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-2 text-xs">
              <dt>Details</dt><dd class="whitespace-pre-line">{@r["details"] || "-"}</dd>
              <dt>Open questions</dt><dd>
                {Enum.join(@r["open_questions"] || [], " · ") |> blank("-")}
              </dd>
              <dt>Rough cost</dt><dd>{@r["rough_cost"] || "-"}</dd>
              <dt>Verdict</dt><dd>{(@r["verdict"] || "-") |> String.replace("_", " ")}</dd>
            </dl>
            <form
              :if={@idea.column == "refining"}
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
              <button type="submit" class="min-h-11 rounded border px-3 font-semibold">Save refinement</button>
            </form>
          </section>

          <section aria-label="Links" class="space-y-1">
            <h5 class="font-semibold">Links</h5>
            <ul class="space-y-0.5">
              <li :for={l <- @idea.links}>
                <span class="text-xs uppercase text-[var(--paper-muted)]">{l.kind}</span>
                <a
                  href={l.url}
                  class="break-all text-[var(--paper-accent)] underline"
                  rel="noopener noreferrer"
                >{l.label || l.url}</a>
              </li>
            </ul>
            <form
              phx-submit="link"
              phx-target={@myself}
              class="grid grid-cols-[auto_minmax(0,1fr)_auto] gap-1"
              id={"card-#{@idea.id}-link"}
            >
              <input type="hidden" name="card_id" value={@idea.id} />
              <select
                name="kind"
                aria-label="Link kind"
                class="min-h-11 rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-1"
              >
                <option :for={k <- Link.kinds()} value={k}>{k}</option>
              </select>
              <input
                name="url"
                type="url"
                required
                placeholder="https://…"
                aria-label="Link URL"
                class="min-w-0 rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-2"
              />
              <button type="submit" class="min-h-11 rounded border px-3">Add</button>
            </form>
          </section>

          <section aria-label="Comments" class="space-y-1">
            <h5 class="font-semibold">Comments</h5>
            <ul class="space-y-1">
              <li :for={c <- @idea.comments} class="rounded bg-[var(--paper-margin)] px-2 py-1">
                <span class="text-xs font-semibold">{who(c.author)}</span>
                <p class="whitespace-pre-line">{c.body}</p>
              </li>
            </ul>
            <form
              phx-submit="comment"
              phx-target={@myself}
              class="grid gap-1"
              id={"card-#{@idea.id}-comment"}
            >
              <input type="hidden" name="card_id" value={@idea.id} />
              <label class="grid gap-1">
                Comment (@case, @bobby or @gentry wakes that bot) <textarea
                  name="body"
                  rows="2"
                  required
                  class="rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-2 py-1"
                ></textarea>
              </label>
              <button type="submit" class="min-h-11 rounded border px-3">Comment</button>
            </form>
          </section>

          <section aria-label="History" class="text-xs text-[var(--paper-muted)]">
            <h5 class="font-semibold">History</h5>
            <ol>
              <li :for={t <- @idea.transitions}>
                {if t.from, do: Rules.label(t.from) <> " → ", else: "Added to "}{Rules.label(t.to)} by {who(
                  t.actor
                )}<span :if={t.note}>: {t.note}</span>
              </li>
            </ol>
          </section>
        </div>
      </details>
    </article>
    """
  end

  defp who("bot:" <> bot), do: String.capitalize(bot)
  defp who(email) when is_binary(email), do: email |> String.split("@") |> hd()
  defp who(_), do: "someone"

  defp blank("", default), do: default
  defp blank(s, _), do: s
end
