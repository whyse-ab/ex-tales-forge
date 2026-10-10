defmodule TalesForgeWeb.TeamBoard do
  @moduledoc """
  Section 6 of the founders' presentation (`/team/presentation`,
  `TalesForgeWeb.TeamPresentationLive`): "How we'll work together: one shared
  board". It is **coming soon and not built**: this is the idea, a picture of
  it, and an animated mock board. There is no working board, nothing to drag
  and no events.

  Copy follows tales-forge-docs `docs/team-page/content.md` section 6 (commits
  a590abc and d118917). The columns come from `shared_board.columns` in
  `data.json` (`id`, `label`, `owner`, `on_enter`), the card from
  `shared_board.sample_card`; a column the data doesn't name keeps the label
  from the brief. A missing or `null` value reads "not measured yet", except
  `on_enter`, where `null` means nothing fires when a card lands there (Ideas
  and Done), so no ping is shown.

  The mock board is server-rendered as the static board the brief asks for
  with `prefers-reduced-motion`: one card in each column, labelled.
  `assets/js/team_hooks.js` (`TeamBoard`) plays the ~8 s story once on
  scroll-in, with a Replay button: the card is dropped into Ideas, Case is
  pinged, the founders comment, a founder's OK stamps the seal and logs the
  decision, Bobby builds it (PR, playtest, Gentry's ✓) and it lands in Done
  with a few d20s. Each column stacks under the one before on a phone (two per
  row from 640 px, all five from 1024 px), so nothing scrolls sideways.
  """

  use TalesForgeWeb, :html

  import TalesForge.TeamPage, only: [get: 2, date_label: 1, count_word: 1]
  import TalesForgeWeb.TeamComponents, only: [section_head: 1]

  alias TalesForge.TeamPage
  alias TalesForgeWeb.TeamArt

  @anchor "board"

  # The five columns as the brief names them, used where the data is silent.
  @default_columns [
    %{"id" => "ideas", "label" => "Ideas", "owner" => "any founder"},
    %{"id" => "refining", "label" => "Refining (Case)", "owner" => "case"},
    %{"id" => "founder_check", "label" => "Founder check", "owner" => "founders"},
    %{"id" => "building", "label" => "Building (Bobby)", "owner" => "bobby", "approval" => true},
    %{"id" => "done", "label" => "Done", "owner" => "crew"}
  ]

  # The step of the animation at which the card reaches each column, and the
  # last step it stays there (Building holds it for the PR and playtest step).
  @steps %{
    "ideas" => {1, 1},
    "refining" => {2, 2},
    "founder_check" => {3, 3},
    "building" => {4, 5},
    "done" => {6, nil}
  }

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

  @doc "The whole section: badge, intro, how a card travels, the mock board and why it works."
  attr :d, :map, required: true

  @spec section(map()) :: Phoenix.LiveView.Rendered.t()
  def section(assigns) do
    board = get(assigns.d, ["shared_board"]) || %{}
    columns = columns(assigns.d)

    assigns =
      assign(assigns,
        anchor: @anchor,
        columns: columns,
        title: get(board, ["sample_card", "title"]) || TeamPage.not_measured(),
        as_of: get(board, ["as_of"]),
        holder: TeamPage.approval_holder(assigns.d)
      )

    ~H"""
    <section
      id={@anchor}
      class="team-section space-y-8"
      aria-labelledby={"#{@anchor}-title"}
      data-reveal
    >
      <p id="board-badge" class="team-badge team-soon">
        <.icon name="hero-sparkles-micro" class="size-4" /> Coming soon. Not built yet.
      </p>
      <.section_head id={@anchor} title="6. How we'll work together: one shared board">
        Soon this page becomes more than a presentation. It becomes the place where founders and bots work side by side:
        one shared board where every feature lives, from a first idea to a shipped change.
        You add an idea, the bots do the legwork, and you decide what gets built.
      </.section_head>

      <div id="board-travel" class="space-y-3">
        <h3 class="font-serif text-xl font-bold sm:text-2xl">How a card travels</h3>
        <p class="text-sm text-[var(--paper-muted)]">
          {count_word(length(@columns)) |> String.capitalize()} columns, from an idea to done.
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

      <.mock_board columns={@columns} title={@title} as_of={@as_of} />

      <ul id="board-why" class="grid gap-3 lg:grid-cols-3" aria-label="Three things that make it work">
        <li class="team-card flex flex-col gap-2 p-4">
          <.icon name="hero-bell-alert" class="size-7 text-[var(--paper-accent)]" />
          <h3 class="font-semibold">Moving a card pings the right bot.</h3>
          <p class="text-sm leading-snug">
            A card in Refining wakes Case, and a card in Building wakes Bobby. Nobody has to keep checking, bots or people.
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
          <h3 class="font-semibold">Everyone holds the key.</h3>
          <p class="text-sm leading-snug">
            Dragging a card to Building is the founder OK. That makes the board a real step toward every founder holding
            the approval key, not just {@holder} as today.
          </p>
        </li>
      </ul>

      <p id="board-small-print" class="max-w-3xl text-xs leading-relaxed text-[var(--paper-muted)]">
        It grows out of what's already there. The app has a founders' decision queue
        (<.link href={~p"/admin/founders/decisions"} class="underline">/admin/founders/decisions</.link>)
        with comments, interest and ranking; the board extends that into a full idea-to-done flow.
        Listed in <a href="/admin/docs/future-ideas.md" class="underline">docs/future-ideas.md</a>
        as “Founder kanban on /team”.
      </p>
    </section>
    """
  end

  attr :id, :string, default: nil

  defp travel(%{id: "ideas"} = assigns) do
    ~H"""
    Any founder adds a feature card, or drags an existing one into the queue. A sentence is enough.
    """
  end

  defp travel(%{id: "refining"} = assigns) do
    ~H"""
    Case picks it up and fills in the card: the details, the open questions and a rough cost.
    """
  end

  defp travel(%{id: "founder_check"} = assigns) do
    ~H"""
    Founders read it, check it's what they meant, and comment. When it's right, a founder drags it to <strong>Building</strong>.
    <em>That drag is the founder's OK.</em>
    """
  end

  defp travel(%{id: "building"} = assigns) do
    ~H"""
    Bobby builds it. The PR link and the playtest link appear right on the card, so you can follow along and try it.
    """
  end

  defp travel(%{id: "done"} = assigns) do
    ~H"""
    Shipped, and the card keeps the whole story.
    """
  end

  defp travel(assigns), do: ~H""

  attr :columns, :list, required: true
  attr :title, :string, required: true
  attr :as_of, :any, default: nil

  defp mock_board(assigns) do
    ~H"""
    <figure
      id="team-board"
      class="team-board team-card space-y-4 p-4 sm:p-6"
      phx-hook="TeamBoard"
      data-board="static"
    >
      <p class="sr-only">
        A mock of the shared board, not a working one: one card, “{@title}”, travels through the columns {Enum.map_join(
          @columns,
          ", ",
          &(&1["label"] || TeamPage.not_measured())
        )}.
      </p>
      <ol id="team-board-columns" class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <li
          :for={{col, i} <- Enum.with_index(@columns, 1)}
          id={"board-col-#{col["id"]}"}
          class="team-board-col flex flex-col gap-2 rounded-lg p-2.5"
          data-column={col["id"]}
        >
          <header class="flex min-h-9 items-center justify-between gap-2">
            <p class="text-sm font-semibold leading-tight">
              <span class="team-board-num">{i}</span> {col["label"] || TeamPage.not_measured()}
            </p>
            <.owner_chip column={col} />
          </header>
          <p :if={is_binary(col["on_enter"])} class="team-board-enter text-[0.7rem] leading-snug">
            <.icon name="hero-bell-micro" class="size-3" /> {col["on_enter"]}
          </p>
          <.card column={col} title={@title} />
        </li>
      </ol>
      <figcaption class="flex flex-wrap items-center justify-between gap-3">
        <span id="board-caption" class="font-serif text-lg">
          Coming soon: one board, the whole crew, from idea to done.
        </span>
        <span class="flex items-center gap-3">
          <span id="board-as-of" class="text-xs text-[var(--paper-muted)]">
            Board plan as of {date_label(@as_of)}
          </span>
          <button
            type="button"
            id="replay-board"
            aria-label="Replay the animation of the shared board"
            class="team-replay-btn min-h-11 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--paper-accent)] inline-flex items-center gap-1.5 rounded-full border border-[var(--paper-rule)] px-3 py-1 text-sm hover:bg-[var(--paper-bg)]"
            data-board-replay
          >
            <.icon name="hero-arrow-path-micro" class="size-4" /> Replay
          </button>
        </span>
      </figcaption>
    </figure>
    """
  end

  attr :column, :map, required: true

  defp owner_chip(assigns) do
    assigns =
      assign(assigns,
        avatar: avatar_for(assigns.column["owner"]),
        ping: at(assigns.column["id"])
      )

    ~H"""
    <span
      :if={@avatar}
      class="team-board-owner relative shrink-0"
      data-at={@ping}
      data-move="pop"
      title={@column["owner"]}
    >
      <TeamArt.avatar id={@avatar} class="size-7" label={owner_label(@avatar)} />
      <span :if={@avatar in ~w(case bobby)} class="team-board-ping">pinged</span>
    </span>
    <span :if={!@avatar && @column["owner"]} class="text-[0.7rem] italic text-[var(--paper-muted)]">
      {@column["owner"]}
    </span>
    """
  end

  attr :column, :map, required: true
  attr :title, :string, required: true

  defp card(assigns) do
    {at, until} = Map.get(@steps, assigns.column["id"], {nil, nil})
    assigns = assign(assigns, at: at, until: until)

    ~H"""
    <div
      class="team-board-card relative space-y-1.5 rounded-md p-2.5 text-xs"
      data-at={@at}
      data-until={@until}
      data-move="slide"
    >
      <p class="font-serif text-sm font-bold leading-tight">{@title}</p>
      <.card_body id={@column["id"]} />
    </div>
    """
  end

  attr :id, :string, default: nil

  defp card_body(%{id: "ideas"} = assigns) do
    ~H"""
    <p class="text-[var(--paper-muted)]">Added by a founder.</p>
    <svg
      viewBox="0 0 24 24"
      class="team-board-cursor absolute -right-1 -top-2 size-6"
      aria-hidden="true"
      fill="var(--paper-panel)"
      stroke="currentColor"
      stroke-width="1.6"
      stroke-linejoin="round"
    >
      <path d="M4.5 3.2 C5 8 5.6 13 6.1 18.4 L9.3 14.6 L12.4 20.6 L15 19.3 L11.9 13.4 L17.1 13.1 C13 9.6 8.9 6.4 4.5 3.2 Z" />
    </svg>
    """
  end

  defp card_body(%{id: "refining"} = assigns) do
    ~H"""
    <ul class="team-board-lines space-y-0.5">
      <li>details</li>
      <li>2 questions</li>
      <li>rough cost: small</li>
    </ul>
    """
  end

  defp card_body(%{id: "founder_check"} = assigns) do
    ~H"""
    <ul class="space-y-1" aria-label="Founders' comments">
      <li
        :for={text <- ["Yes, exactly!", "Only after the second visit?", "👍"]}
        class="flex items-start gap-1.5"
      >
        <TeamArt.avatar id="founders" class="size-5" label="A founder" />
        <span class="team-board-bubble">{text}</span>
      </li>
    </ul>
    """
  end

  defp card_body(%{id: "building"} = assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <TeamArt.picture
        name="founders-seal"
        sizes="40px"
        alt="The founders' seal"
        class="team-board-seal size-10 rounded-full object-cover"
      />
      <span class="font-semibold text-[var(--team-seal)]">Founder OK</span>
    </div>
    <p class="flex items-center gap-1.5">
      <span class="team-board-chip team-board-fly">decision logged</span>
      <.icon name="hero-document-text" class="size-4 text-[var(--paper-muted)]" />
    </p>
    <p class="flex flex-wrap items-center gap-1" data-at="5" data-move="pop">
      <span class="team-board-chip">PR</span>
      <span class="team-board-chip">playtest</span>
      <span class="team-board-chip inline-flex items-center gap-1">
        <TeamArt.avatar id="gentry" class="size-4" label="Gentry" /> ✓
      </span>
    </p>
    """
  end

  defp card_body(%{id: "done"} = assigns) do
    ~H"""
    <p class="team-board-shipped font-semibold">Shipped</p>
    <p class="text-[var(--paper-muted)]">The card keeps the whole story.</p>
    <span class="team-board-confetti pointer-events-none absolute inset-0" aria-hidden="true">
      <TeamArt.d20 :for={n <- 1..4} class={"team-board-d20 team-board-d20-#{n} absolute size-4"} />
    </span>
    """
  end

  defp card_body(assigns), do: ~H""

  defp at(id), do: @steps |> Map.get(id, {nil, nil}) |> elem(0)

  defp avatar_for(owner) when owner in ~w(case bobby founders), do: owner
  defp avatar_for(_owner), do: nil

  defp owner_label("founders"), do: "The founders"
  defp owner_label(id), do: String.capitalize(id)
end
