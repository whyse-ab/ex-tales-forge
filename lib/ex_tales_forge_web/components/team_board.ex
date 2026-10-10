defmodule TalesForgeWeb.TeamBoard do
  @moduledoc """
  Section 6 of the founders' presentation (`/team/presentation`,
  `TalesForgeWeb.TeamPresentationLive`): "How we work together: one shared
  board". The idea board is live on `/team` (`#idea-board`, since
  2026-10-10), and founders and bots use it every day. This section explains
  how a card travels and shows the live board: the real columns with their
  card counts, and the team totals (cards, votes, founder comments, PR
  approvals and how many founders take part) from `TalesForge.Board.stats/0`.
  It also lists what is new on the board (`#board-new`): the Ideas
  lane's sort toggle, tags, tag cloud and Pings for you, the column portraits,
  Bobby's pickup note, approve once and Case's hourly check. It shows team totals only, with no founder names (board card
  "update presentation after shared workarea", answered 2026-10-10). The
  section reads; it has nothing to drag and sends no events.

  The rules follow tales-forge-docs `docs/design-board-states.md` (approved
  2026-10-10), and the copy follows `docs/team-page/content.md` section 6.
  The "How a card travels" steps come from `shared_board.columns` in
  `data.json` (`id`, `label`, `owner`); a column that the data does not name
  keeps the label from the brief. Without stats (where the board is not, or a
  render with data only), each count reads "not measured yet", never a zero.
  The columns stack two per row on a phone (three from 640 px, all six from
  1024 px), so nothing scrolls sideways.
  """

  use TalesForgeWeb, :html

  import TalesForge.TeamPage, only: [get: 2, count_word: 1]
  import TalesForgeWeb.TeamComponents, only: [section_head: 1]

  alias TalesForge.Board.Idea
  alias TalesForge.Board.Transitions
  alias TalesForge.TeamPage

  @anchor "board"

  # The five columns as the brief names them, used where the data is silent.
  @default_columns [
    %{"id" => "ideas", "label" => "Ideas", "owner" => "any founder"},
    %{"id" => "refining", "label" => "Refining (Case)", "owner" => "case"},
    %{"id" => "founder_check", "label" => "Founder check", "owner" => "founders"},
    %{"id" => "building", "label" => "Building (Bobby)", "owner" => "bobby", "approval" => true},
    %{"id" => "done", "label" => "Done", "owner" => "crew"}
  ]

  # The team totals under the live board, in order.
  @total_labels [
    cards: "Cards",
    votes: "Votes",
    comments: "Founder comments",
    approvals: "PR approvals",
    founders: "Founders taking part"
  ]

  @doc """
  The anchor (element id) of the section.

      iex> TalesForgeWeb.TeamBoard.anchor()
      "board"
  """
  @spec anchor() :: String.t()
  def anchor, do: @anchor

  @doc """
  The board's columns: `shared_board.columns` from the data, each filled in
  from the brief's five columns where a value is missing; the brief's five
  when the data has none.

      iex> [first | _] = TalesForgeWeb.TeamBoard.columns(%{})
      iex> first["label"]
      "Ideas"
      iex> cols = %{"shared_board" => %{"columns" => [%{"id" => "ideas", "label" => nil}]}}
      iex> TalesForgeWeb.TeamBoard.columns(cols) |> Enum.map(& &1["label"])
      ["Ideas"]
  """
  @spec columns(map()) :: [map()]
  def columns(data) do
    case get(data, ["shared_board", "columns"]) do
      [_ | _] = cols -> Enum.map(cols, &fill_column/1)
      _missing -> @default_columns
    end
  end

  defp fill_column(%{} = col) do
    default = Enum.find(@default_columns, %{}, &(&1["id"] == col["id"]))
    Map.merge(default, col, fn _key, old, new -> if is_nil(new), do: old, else: new end)
  end

  defp fill_column(_other), do: %{}

  @doc "The whole section: badge, intro, how a card travels, the live board and why it works."
  attr :d, :map, required: true

  attr :live, :map,
    default: nil,
    doc: "`TalesForge.Board.stats/0`, or `nil` where the board is not"

  @spec section(map()) :: Phoenix.LiveView.Rendered.t()
  def section(assigns) do
    columns = columns(assigns.d)

    assigns =
      assign(assigns,
        anchor: @anchor,
        columns: columns,
        total_labels: @total_labels
      )

    ~H"""
    <section
      id={@anchor}
      class="team-section space-y-8"
      aria-labelledby={"#{@anchor}-title"}
      data-reveal
    >
      <p id="board-badge" class="team-badge">
        <.icon name="hero-check-circle-micro" class="size-4" /> Live on
        <.link href="/team#idea-board" class="underline">/team</.link>
      </p>
      <.section_head id={@anchor} title="6. How we work together: one shared board">
        The idea board on /team is where founders and bots work side by side.
        Every feature lives there, from a first idea to a change on production.
        You add an idea, the bots do the legwork, and you decide what gets built.
      </.section_head>

      <div id="board-travel" class="space-y-3">
        <h3 class="font-serif text-xl font-bold sm:text-2xl">How a card travels</h3>
        <p class="text-sm text-[var(--paper-muted)]">
          {count_word(length(@columns) + 1) |> String.capitalize()} columns. A card goes through {count_word(
            length(@columns)
          )} of them, from an idea to done. The sixth, <strong>Parked</strong>,
          holds a card for later; a founder can send it back to Ideas.
        </p>
        <ol class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
          <li
            :for={{col, i} <- Enum.with_index(@columns, 1)}
            id={"board-step-#{col["id"]}"}
            class="team-card flex flex-col gap-2 p-4"
          >
            <p class="flex items-center gap-2 font-semibold leading-tight">
              <span class="team-board-num">{i}</span> {col["label"] || TeamPage.not_measured()}
            </p>
            <p class="text-sm leading-snug"><.travel id={col["id"]} /></p>
          </li>
        </ol>
      </div>

      <.live_board live={@live} total_labels={@total_labels} />

      <.new_on_board />

      <ul id="board-why" class="grid gap-3 lg:grid-cols-3" aria-label="Three things that make it work">
        <li class="team-card flex flex-col gap-2 p-4">
          <.icon name="hero-bell-alert" class="size-7 text-[var(--paper-accent)]" />
          <h3 class="font-semibold">Moving a card pings the right bot.</h3>
          <p class="text-sm leading-snug">
            A card in Refining wakes Case, and a card in Building wakes Bobby. When a comment names a bot, that bot wakes too.
            Nobody has to keep checking, bots or people.
          </p>
        </li>
        <li class="team-card flex flex-col gap-2 p-4">
          <.icon name="hero-document-check" class="size-7 text-[var(--paper-accent)]" />
          <h3 class="font-semibold">One place for each thing.</h3>
          <p class="text-sm leading-snug">
            When a card is approved, it writes its own entry in the decision log (<code>docs/decisions.md</code>),
            so the board and the log never disagree.
          </p>
        </li>
        <li class="team-card flex flex-col gap-2 p-4">
          <.icon name="hero-key" class="size-7 text-[var(--paper-accent)]" />
          <h3 class="font-semibold">Every founder decides.</h3>
          <p class="text-sm leading-snug">
            Any founder can send a card to Building, and that move is the founder OK. Any founder also approves the PR on the card. The approved change goes to playtest, Gentry checks it, and then it ships to production by itself.
          </p>
        </li>
      </ul>

      <p id="board-small-print" class="max-w-3xl text-xs leading-relaxed text-[var(--paper-muted)]">
        The board grew out of the founders' decision queue
        (<.link href={~p"/admin/founders/decisions"} class="underline">/admin/founders/decisions</.link>).
        The rules for every move are in <a href="/admin/docs/design-board-states.md" class="underline">docs/design-board-states.md</a>.
      </p>
    </section>
    """
  end

  # What is new on the board (live since 2026-10-10): the Ideas lane tools,
  # the column portraits, Bobby's pickup note, approve once and the hourly check.
  defp new_on_board(assigns) do
    ~H"""
    <div id="board-new" class="space-y-3">
      <h3 class="font-serif text-xl font-bold sm:text-2xl">New on the board</h3>
      <ul class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <li id="board-new-ideas" class="team-card flex flex-col gap-2 p-4">
          <.icon name="hero-tag" class="size-7 text-[var(--paper-accent)]" />
          <h4 class="font-semibold">The Ideas lane finds the card you want.</h4>
          <p class="text-sm leading-snug">
            One icon sorts the lane: newest first or oldest first. Each card shows its tags. A founder's name becomes a tag by itself,
            and you can add your own free tags. Select tags in the tag cloud to show the cards that have all of them.
            The link keeps your selection, so you can share it. <strong>Pings for you</strong>
            shows each comment that mentions you.
          </p>
        </li>
        <li id="board-new-portraits" class="team-card flex flex-col gap-2 p-4">
          <.icon name="hero-user-circle" class="size-7 text-[var(--paper-accent)]" />
          <h4 class="font-semibold">Each bot column shows its bot.</h4>
          <p class="text-sm leading-snug">
            Case's portrait is behind Refining, and Bobby's portrait is behind Building. You see at a glance who works on a card.
          </p>
        </li>
        <li id="board-new-pickup" class="team-card flex flex-col gap-2 p-4">
          <.icon name="hero-wrench-screwdriver" class="size-7 text-[var(--paper-accent)]" />
          <h4 class="font-semibold">Bobby says when the work starts.</h4>
          <p class="text-sm leading-snug">
            When a card moves to Building, Bobby writes “Picked up by Bobby. ETA ...” on the card at once.
          </p>
        </li>
        <li id="board-new-approve-once" class="team-card flex flex-col gap-2 p-4">
          <.icon name="hero-hand-thumb-up" class="size-7 text-[var(--paper-accent)]" />
          <h4 class="font-semibold">You approve once.</h4>
          <p class="text-sm leading-snug">
            Your Approve stays when a later commit is only a rebase or a fix. The card history notes the new commit.
            The founders get the question again only when what players get changes.
          </p>
        </li>
        <li id="board-new-hourly" class="team-card flex flex-col gap-2 p-4">
          <.icon name="hero-clock" class="size-7 text-[var(--paper-accent)]" />
          <h4 class="font-semibold">An hourly check keeps Building moving.</h4>
          <p class="text-sm leading-snug">
            Every hour, Case looks at the Building column. When a card has no PR after more than one hour, Case reminds Bobby.
          </p>
        </li>
      </ul>
    </div>
    """
  end

  attr :id, :string, default: nil

  defp travel(%{id: "ideas"} = assigns) do
    ~H"""
    Any founder adds a card. A sentence is enough. Votes set the order: a card needs an upvote to move,
    and a downvote (with a reason) stops it until that founder takes it back. Tags and a tag cloud help you find a card.
    """
  end

  defp travel(%{id: "refining"} = assigns) do
    ~H"""
    Case fills in the card: the details, the open questions and a rough cost. Then Case sends it to Founder check. Case's portrait is behind this column.
    """
  end

  defp travel(%{id: "founder_check"} = assigns) do
    ~H"""
    Founders read it, check it is what they meant, and answer the open questions. Then a founder sends it to <strong>Building</strong>.
    <em>That move is the founder's OK.</em>
    """
  end

  defp travel(%{id: "building"} = assigns) do
    ~H"""
    Bobby writes “Picked up by Bobby. ETA ...” on the card at once, builds it and links the PR to the card. The PR's status (open, merged, on production) shows on the card, so you can follow along and try it. Bobby's portrait is behind this column.
    """
  end

  defp travel(%{id: "done"} = assigns) do
    ~H"""
    On production. Bobby can move a card to Done only when the PR's merge commit runs on production. The card keeps the whole story.
    """
  end

  defp travel(assigns), do: ~H""

  attr :live, :map, default: nil
  attr :total_labels, :list, required: true

  defp live_board(assigns) do
    ~H"""
    <figure id="team-board" class="team-board team-card space-y-4 p-4 sm:p-6">
      <ol
        id="team-board-columns"
        class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6"
        aria-label="Cards in each column of the idea board now"
      >
        <li
          :for={col <- columns_now(@live)}
          id={"board-col-#{col.id}"}
          class="team-board-col flex flex-col justify-between gap-1 rounded-lg p-3"
          data-column={col.id}
        >
          <p class="text-sm font-semibold leading-tight">{col.label}</p>
          <p class="team-board-count font-serif text-3xl font-bold" data-count={col.count}>
            {count_text(col.count)}
          </p>
        </li>
      </ol>
      <div id="board-totals" class="space-y-2">
        <h3 class="font-serif text-lg font-bold">What we did together on the board</h3>
        <dl class="grid grid-cols-2 gap-3 sm:grid-cols-5">
          <div
            :for={{key, label} <- @total_labels}
            id={"board-total-#{key}"}
            class="team-board-col rounded-lg p-3"
          >
            <dt class="text-xs text-[var(--paper-muted)]">{label}</dt>
            <dd class="font-serif text-2xl font-bold">{count_text(total(@live, key))}</dd>
          </div>
        </dl>
        <p class="text-xs text-[var(--paper-muted)]">
          Team totals since the board opened. We count what the team does together, not who does it.
        </p>
      </div>
      <figcaption class="flex flex-wrap items-center justify-between gap-3">
        <span id="board-caption" class="font-serif text-lg">
          One board, the whole crew, from idea to done.
        </span>
        <span id="board-live-note" class="text-xs text-[var(--paper-muted)]">
          {if @live,
            do: "Live from the idea board. It updates when a card changes.",
            else: "Live counts show on production."}
        </span>
        <.link
          href="/team#idea-board"
          class="text-sm font-semibold text-[var(--paper-accent)] underline"
        >
          Open the idea board →
        </.link>
      </figcaption>
    </figure>
    """
  end

  @doc """
  The columns of the live board: the columns of `TalesForge.Board.stats/0`,
  or the board's columns with no count (`nil`) when there are no stats.

      iex> TalesForgeWeb.TeamBoard.columns_now(nil) |> Enum.map(& &1.count) |> Enum.uniq()
      [nil]
      iex> TalesForgeWeb.TeamBoard.columns_now(%{columns: [%{id: "ideas", label: "Ideas", count: 3}]})
      [%{id: "ideas", label: "Ideas", count: 3}]
  """
  @spec columns_now(TalesForge.Board.stats() | nil) :: [map()]
  def columns_now(%{columns: columns}), do: columns

  def columns_now(_none) do
    Enum.map(Idea.columns(), &%{id: &1, label: Transitions.label(&1), count: nil})
  end

  defp total(%{totals: totals}, key), do: Map.get(totals, key)
  defp total(_none, _key), do: nil

  defp count_text(n) when is_integer(n), do: Integer.to_string(n)
  defp count_text(_none), do: TeamPage.not_measured()
end
