defmodule TalesForgeWeb.TeamPresentationLive do
  @moduledoc """
  The founders' full presentation at `/team/presentation`: who the crew is
  (the founders and three bots), how a change gets from an idea to the game,
  how we work, what the game runs on, what the persona playtests and Gentry
  found, the pace and cost so far, the shared board that founders and bots use
  every day (section 6, live columns, card counts and team totals) and how to
  take part, with the board first (section 7). Fredrik presents from
  it. `/team` (`TalesForgeWeb.TeamLive`) is the light landing page that links
  here.

  Old `/team#section` links are forwarded here by the landing page's anchor
  hook, for the anchors in `anchors/0`.

  Behind the GitHub team sign-in like every page (router `:browser` pipeline
  plus the `:require_team_member` mount hook, the same `:play` live session as
  `/team`). Read-only: no events, no AI calls, no GitHub calls. It subscribes
  to the PR feed's PubSub topic and, where the board is
  (`TalesForge.AppRole.here?(:board)`), to `TalesForge.Board`'s topic: each
  board change reloads the counts of `TalesForge.Board.stats/0`.

  Copy follows tales-forge-docs `docs/team-page/content.md` (commit d118917,
  2026-10-09). The pace numbers (pull requests, merged, open, per day, and
  commits on main) come from one place, `TalesForge.TeamPace.current/0`, for
  both the headline stats and section 5: live from GitHub through the PR feed
  (updated on every feed broadcast), or `data.json` labelled "as of <date>"
  when the feed has no full count. Every other number comes from
  `TalesForge.TeamPage` (the bundled `data.json`); a missing or empty value
  reads "not measured yet". Charts are
  `TalesForgeWeb.TeamComponents`, pictures `TalesForgeWeb.TeamArt`, the header
  and footer `TalesForgeWeb.TeamLayout`. The animations (sections fading in,
  bars growing, the d20 rolling through the change flow, the three call-type
  lanes of `TalesForgeWeb.TeamCallTypes`) run
  in `assets/js/team_hooks.js` and are off with
  `prefers-reduced-motion`: the root then carries `data-motion="reduce"` and
  the static diagram is shown. The page follows the header theme toggle
  (`.paper-themed`), so dark mode works.
  """

  use TalesForgeWeb, :live_view

  import TalesForge.TeamPage,
    only: [
      get: 2,
      number: 1,
      number: 2,
      usd: 1,
      pct: 1,
      ms: 1,
      score: 1,
      count_word: 1,
      date_label: 1
    ]

  import TalesForgeWeb.TeamComponents

  alias TalesForge.AppRole
  alias TalesForge.PrFeed
  alias TalesForge.PrFeed.Extras
  alias TalesForge.TeamPace
  alias TalesForge.TeamPage
  alias TalesForgeWeb.Layouts
  alias TalesForgeWeb.TeamArt
  alias TalesForgeWeb.TeamBoard
  alias TalesForgeWeb.TeamCallTypes
  alias TalesForgeWeb.TeamLayout
  alias TalesForgeWeb.TeamLiveNumbers

  @sections [
    {"team", "Team"},
    {"how", "How we work"},
    {"infrastructure", "Infrastructure"},
    {"playtests", "Playtests"},
    {"pace", "Pace and cost"},
    {TeamBoard.anchor(), "One shared board"},
    {"together", "Together"}
  ]

  # Every place on this page an old `/team#...` link could point at: the
  # sections, plus the named parts inside them. The landing page forwards
  # these (and only these) to `/team/presentation#...`.
  @anchors Enum.map(@sections, &elem(&1, 0)) ++
             ~w(hero starting-point team-cards) ++
             Enum.map(~w(founders case bobby gentry), &("member-" <> &1)) ++
             ~w(flow rule-decisions rule-call-types) ++
             [TeamCallTypes.anchor()] ++
             ~w(stack hosting architecture persona-cards shadow-test intent-compare eval-set gentry hostile-play ai-spend)

  @flow_detail %{
    "idea" => "A founder adds a card on the idea board. Votes set the order.",
    "case" => "Case writes the details, the open questions and a rough cost.",
    "pr" => "Bobby builds it as a pull request and links the PR to the card.",
    "merge" => "Into main, the shared version of the code.",
    "review" => "Case's architecture review of what just landed.",
    "playtest" =>
      "Our separate copy of the game for testing. Every merge goes here first, by itself.",
    "prod" =>
      "Where players are. Admin-only changes (the fast lane) go here by themselves after playtest. Other changes go here with \"Deploy to production\".",
    "done" =>
      "Bobby moves the card to Done. The board allows it only when the merge commit runs on production."
  }

  @category_labels %{
    "real_turn" => "Real playtest turns",
    "attack_prompt_injection" => "Attack: prompt injection",
    "attack_jailbreak" => "Attack: jailbreak",
    "attack_nefarious" => "Attack: nefarious request",
    "multi_action" => "Tricky: several actions at once",
    "plan_vs_action" => "Tricky: a plan, not an action",
    "quoted_vs_narration" => "Tricky: quoted speech vs narration",
    "out_of_character" => "Tricky: out of character",
    "in_story_violence" => "Tricky: in-story violence",
    "lie" => "Tricky: the player lies"
  }

  @doc """
  The sections of the presentation, in order, as `{anchor, nav label}`.

      iex> TalesForgeWeb.TeamPresentationLive.sections() |> Enum.map(&elem(&1, 1)) |> Enum.take(-2)
      ["One shared board", "Together"]
  """
  @spec sections() :: [{String.t(), String.t()}]
  def sections, do: @sections

  @doc """
  The anchors (element ids) of this page that an old `/team#anchor` link may
  use: every section of the nav, then the named parts inside them.

      iex> anchors = TalesForgeWeb.TeamPresentationLive.anchors()
      iex> Enum.take(anchors, 8)
      ["team", "how", "infrastructure", "playtests", "pace", "board", "together", "hero"]
      iex> "the-call-type-rule-one-turn-three-call-types" in anchors
      true
  """
  @spec anchors() :: [String.t()]
  def anchors, do: @anchors

  @doc """
  Where an old `/team#anchor` link lands now: the same anchor on the
  presentation, or `nil` when the anchor isn't one of `anchors/0`.

      iex> TalesForgeWeb.TeamPresentationLive.presentation_path("playtests")
      "/team/presentation#playtests"
      iex> TalesForgeWeb.TeamPresentationLive.presentation_path("crew")
      nil
  """
  @spec presentation_path(String.t()) :: String.t() | nil
  def presentation_path(anchor) when anchor in @anchors, do: "/team/presentation#" <> anchor
  def presentation_path(_anchor), do: nil

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    if connected?(socket), do: PrFeed.subscribe()
    d = TeamPage.data()

    {:ok,
     socket
     |> assign(:page_title, "Team · presentation")
     |> assign(:d, d)
     |> assign(:pace, TeamPace.current(PrFeed.snapshot(), d))
     |> assign(:live, TeamLiveNumbers.all(d, Extras.current()))
     |> assign(:board_live, board_live(socket))
     |> assign(:sections, @sections)}
  end

  # Each new feed snapshot (about once a minute) refreshes every live group:
  # the PR pace, the GitHub extras and this app's database numbers.
  @impl true
  def handle_info({:board, :changed}, socket),
    do: {:noreply, assign(socket, :board_live, TalesForge.Board.stats())}

  def handle_info({:pr_feed, snapshot}, socket) do
    d = socket.assigns.d

    {:noreply,
     socket
     |> assign(:pace, TeamPace.current(snapshot, d))
     |> assign(:live, TeamLiveNumbers.all(d, Extras.current()))}
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    # Rendered without a mount (tests call render/1 with just `d`): the
    # numbers of `d` itself, as the fallback.
    assigns = Map.put_new_lazy(assigns, :pace, fn -> TeamPace.from_data(assigns.d) end)
    assigns = Map.put_new_lazy(assigns, :live, fn -> TeamLiveNumbers.fallback(assigns.d) end)
    assigns = Map.put_new(assigns, :board_live, nil)

    ~H"""
    <div
      id="team-page"
      class="team-page paper-themed paper-home min-h-dvh"
      phx-hook="TeamPage"
      data-motion="auto"
    >
      <TeamLayout.header socket={assigns[:socket]} page={:presentation} items={@sections} />

      <main class="mx-auto max-w-6xl space-y-20 px-4 pb-16 pt-8 sm:px-6 sm:pt-12">
        <.hero d={@d} pace={@pace} live={@live} />
        <.team_section d={@d} />
        <.how_section d={@d} live={@live} />
        <.infra_section d={@d} />
        <.playtests_section d={@d} live={@live} />
        <.pace_section d={@d} pace={@pace} live={@live} />
        <TeamBoard.section d={@d} live={@board_live} />
        <.together_section d={@d} />
      </main>

      <TeamLayout.footer d={@d} />
      <Layouts.flash_group flash={@flash} />
    </div>
    """
  end

  # The live board's team totals where the board is, else `nil`.
  defp board_live(socket) do
    if AppRole.here?(:board) do
      if connected?(socket), do: TalesForge.Board.subscribe()
      TalesForge.Board.stats()
    end
  end

  # ── 0. Hero ────────────────────────────────────────────────────────────────

  attr :d, :map, required: true
  attr :pace, :map, required: true, doc: "`TalesForge.TeamPace.current/0`"
  attr :live, :map, required: true, doc: "`TalesForgeWeb.TeamLiveNumbers.all/3`"

  defp hero(assigns) do
    ~H"""
    <section
      id="hero"
      class="grid items-center gap-8 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]"
      data-reveal
    >
      <div class="space-y-5">
        <h1 class="font-serif text-4xl font-bold leading-tight sm:text-5xl">
          How Tales Forge gets built
        </h1>
        <p class="text-lg leading-relaxed text-[var(--paper-muted)]">
          The founders and {count_word(bot_count(@d))} bots, one crew, taking a lot of small, careful steps.
          Here's who does what, how a change gets from an idea to the game, and what we've learned from letting bots play it.
        </p>
        <aside id="starting-point" class="team-callout flex gap-3 p-4">
          <TeamArt.seal class="size-10 shrink-0" />
          <p class="text-sm leading-relaxed sm:text-base">
            <strong>This is how we work today, and it's a starting point.</strong>
            Every founder approves PRs on the idea board: send a card to Building, then approve its PR on the card. {holder(
              @d
            )} pushes the production releases of the normal lane. This page is an invitation to shape the rest with us.
          </p>
        </aside>
      </div>
      <div class="team-card overflow-hidden p-3">
        <TeamArt.picture
          id="hero-art"
          name="hero"
          sizes="(min-width: 1152px) 528px, (min-width: 1024px) calc(50vw - 3rem), calc(100vw - 3.5rem)"
          loading="eager"
          fetchpriority="high"
          class="block aspect-video h-auto w-full rounded-lg object-cover"
        />
      </div>
      <div class="grid gap-3 sm:grid-cols-3 lg:col-span-2">
        <.stat
          id="stat-prs-merged"
          value={number(@pace.prs_merged)}
          label="pull requests merged"
        >
          <.explain text="a pull request, or PR, is one proposed change to the code that someone reviews before it goes in" />
        </.stat>
        <.stat
          id="stat-decisions"
          value={number(@live.decisions.total)}
          label="decisions written down"
        />
        <.stat
          id="stat-tests"
          value={number(tests_total(@live.tests))}
          label={tests_label(@live.tests)}
        />
        <div id="stat-source" class="space-y-0.5 sm:col-span-3">
          <.pace_source id="stat-source-prs" pace={@pace} />
          <.group_source id="stat-source-decisions" what="Decisions" group={@live.decisions} />
          <.group_source id="stat-source-tests" what="Tests" group={@live.tests} />
        </div>
      </div>
    </section>
    """
  end

  # ── 1. The team ────────────────────────────────────────────────────────────

  attr :d, :map, required: true

  defp team_section(assigns) do
    assigns = assign(assigns, :steps, get(assigns.d, ["change_flow", "steps"]) || [])

    ~H"""
    <section id="team" class="team-section space-y-8" aria-labelledby="team-title" data-reveal>
      <.section_head id="team" title="1. The team">
        Tales Forge is built by one crew: the founders and {count_word(bot_count(@d))} bots. The bots do a lot of the hands-on work,
        and nothing reaches the game without a founder's yes. Any founder gives that yes on the board.
      </.section_head>

      <ul id="team-cards" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <li
          :for={member <- get(@d, ["team", "members"]) || []}
          id={"member-#{member["id"]}"}
          class="team-card flex flex-col gap-3 p-4"
        >
          <TeamArt.picture
            :if={TeamArt.portrait?(member["id"])}
            id={"portrait-#{member["id"]}"}
            name={member["id"]}
            sizes="(min-width: 1152px) 240px, (min-width: 1024px) calc(25vw - 3rem), (min-width: 640px) calc(50vw - 4rem), calc(100vw - 4rem)"
            class="team-portrait block aspect-[4/3] h-auto w-full rounded-lg object-cover"
          />
          <div class="flex items-center gap-3">
            <TeamArt.avatar
              :if={!TeamArt.portrait?(member["id"])}
              id={member["id"]}
              class="size-16"
              label={"#{member["name"]}"}
            />
            <div class="min-w-0">
              <h3 class="font-serif text-lg font-bold leading-tight">{member["name"]}</h3>
              <p class="text-xs text-[var(--paper-muted)]">
                {member["role"]} <span class="italic">({kind_label(member)})</span>
              </p>
            </div>
          </div>
          <ul class="team-bullets flex-1 space-y-1.5 text-sm leading-snug">
            <.member_bullets id={member["id"]} d={@d} />
          </ul>
          <.member_badge member={member} />
        </li>
      </ul>
      <p class="rounded-lg border border-dashed border-[var(--paper-rule)] px-4 py-3 text-sm text-[var(--paper-muted)]">
        There are also a few helper bots for company admin, like bookkeeping, invoices and mail. They don't work on the game.
      </p>

      <div id="flow" class="space-y-4">
        <h3 class="font-serif text-xl font-bold sm:text-2xl">How a change flows</h3>
        <p class="max-w-3xl leading-relaxed text-[var(--paper-muted)]">
          Every change starts as a card on the idea board and ends on production. Most steps take minutes: the median PR went from opened to merged
          in about {median_minutes(@d)} minutes in October. Every merge goes to playtest first. Then the lane decides the rest.
          <strong>Fast lane:</strong>
          a change that only touches admin pages goes on to production by itself.
          <strong>Normal lane:</strong>
          Gentry and the persona bots play it first, and a founder gives the OK to ship.
        </p>
        <.flow steps={@steps} d={@d} />
        <p class="text-xs text-[var(--paper-muted)]">
          Median time from a PR being opened to merged in October: {number(
            get(@d, ["pace", "median_hours_open_to_merge_oct"])
          )} h
          (about {median_minutes(@d)} min). Deploy order: playtest first, then production (decided 9 Oct 2026). Fast lane since 9 Oct 2026; board rules approved 10 Oct 2026.
        </p>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :d, :map, required: true

  defp member_bullets(%{id: "founders"} = assigns) do
    ~H"""
    <li>Shape what we build: ideas, surveys and playing the game.</li>
    <li>Make the decisions, written down in one shared log.</li>
    <li>
      Approve PRs on the board.
      <strong>Every founder holds the approval key; {holder(@d)} pushes the normal-lane production releases.</strong>
    </li>
    <li :if={get(@d, ["team", "members", 0, "people", "names"]) not in [nil, []]}>
      <.founders_people id="founders-people" d={@d} />
    </li>
    """
  end

  defp member_bullets(%{id: "case"} = assigns) do
    ~H"""
    <li>
      The crew's go-to bot. Refines the cards on the idea board: details, open questions and a rough cost.
    </li>
    <li>
      Reviews the architecture on every merge, in the spirit of <em>The Pragmatic Programmer</em>
      <.explain text="a classic book on keeping code simple: don't repeat yourself, fix broken windows early, keep decisions reversible" />.
    </li>
    <li>
      Posts an hourly status, cleans up old branches every day, and does the research and analyses behind our decisions.
    </li>
    """
  end

  defp member_bullets(%{id: "bobby"} = assigns) do
    ~H"""
    <li>Writes all the code, always as pull requests.</li>
    <li>
      Runs the persona playtests and the evals
      <.explain text="an eval is a fixed test set we score the AI against, so we can tell if a change made it better or worse" />.
    </li>
    <li>
      Ships to Fly
      <.explain text="our hosting" />. Admin-only changes take the fast lane and ship by themselves when the checks pass.
      Every other change reaches production when {holder(@d)} pushes the release, after a founder's OK on the board.
    </li>
    <li>Checks the Fly logs every hour.</li>
    """
  end

  defp member_bullets(%{id: "gentry"} = assigns) do
    ~H"""
    <li>
      Plays the game like a troublemaker: prompt injections
      <.explain text="text that tries to trick the AI into ignoring its rules" />, fake GM notes and false claims
      (“the GM already said I have the sword”).
    </li>
    <li>Also checks broken links, speed, phone layout and accessibility.</li>
    <li>
      Every attack Gentry finds goes into the intent eval set, so the game gets harder to fool over time.
    </li>
    <li>Never touches production.</li>
    """
  end

  defp member_bullets(assigns) do
    ~H"""
    <li :for={line <- get(@d, ["team", "members"]) |> find_member(@id) |> Map.get("does", [])}>
      {line}
    </li>
    """
  end

  attr :member, :map, required: true

  defp member_badge(%{member: %{"approval_key" => %{"holder_today" => holder}}} = assigns)
       when is_binary(holder) do
    assigns = assign(assigns, holder: holder)

    ~H"""
    <p class="team-badge">
      <TeamArt.seal class="size-4" /> The approval key: every founder, on the board
    </p>
    """
  end

  defp member_badge(%{member: %{"schedule" => schedule, "id" => id}} = assigns)
       when is_binary(schedule) do
    assigns = assign(assigns, :text, badge_text(id, schedule))

    ~H"""
    <p class="team-badge"><.icon name="hero-clock-micro" class="size-4" /> {@text}</p>
    """
  end

  defp member_badge(assigns), do: ~H""

  defp badge_text("case", _schedule), do: "Hourly status · daily cleanup"
  defp badge_text("bobby", _schedule), do: "Hourly log check"
  defp badge_text("gentry", _schedule), do: "Weekdays 07:13 · after every playtest deploy"
  defp badge_text(_id, schedule), do: schedule

  attr :steps, :list, required: true
  attr :d, :map, required: true

  defp flow(assigns) do
    ~H"""
    <figure
      id="team-flow"
      class="team-flow team-card relative p-4 sm:p-6"
      phx-hook="TeamFlow"
      data-flow="static"
    >
      <figcaption class="sr-only">
        The path of a change, step by step: {Enum.map_join(@steps, ", ", & &1["label"])}.
      </figcaption>
      <ol
        id="team-flow-steps"
        class="team-flow-track relative grid gap-4 lg:grid-cols-13 lg:gap-1"
        data-flow-track
      >
        <div class="team-flow-line" aria-hidden="true" />
        <li
          :for={{step, i} <- Enum.with_index(@steps, 1)}
          id={"flow-step-#{step["id"]}"}
          class="team-flow-step relative flex items-start gap-3 lg:flex-col lg:items-center lg:gap-2 lg:text-center"
          data-flow-step
          data-approval={step["approval"] && "true"}
        >
          <div
            class="relative flex size-12 shrink-0 items-center justify-center rounded-full bg-[var(--paper-panel)]"
            data-flow-marker
          >
            <%= if step["approval"] do %>
              <TeamArt.picture
                name="founders-seal"
                sizes="48px"
                class="team-seal size-12 rounded-full object-cover"
              />
              <TeamArt.avatar
                id="founders"
                class="absolute -bottom-1 -right-1 size-6"
                label="The founders"
              />
            <% else %>
              <.step_owners who={step["who"]} />
            <% end %>
          </div>
          <div class="min-w-0 pt-1 lg:pt-0">
            <p class="text-sm font-semibold leading-tight lg:text-[0.78rem]">
              <span class="text-[var(--paper-muted)] lg:hidden">{i}.</span> {step["label"]}
            </p>
            <p :if={!step["approval"]} class="text-xs text-[var(--paper-muted)] lg:text-[0.68rem]">
              {owner_text(step["who"], @d)}
            </p>
            <p
              :if={step["approval"]}
              class="team-seal-caption mt-1 text-xs font-semibold text-[var(--team-seal)] lg:text-[0.68rem]"
            >
              {seal_caption(step["id"], @d)}
            </p>
            <p :if={!step["approval"]} class="mt-1 text-xs leading-snug lg:hidden">
              <.step_detail id={step["id"]} d={@d} />
            </p>
          </div>
        </li>
        <TeamArt.d20
          class="team-flow-token pointer-events-none absolute left-0 top-0 z-20 size-9"
          data-flow-token
        />
      </ol>
      <ol class="mt-6 hidden gap-x-6 gap-y-1 border-t border-[var(--paper-rule)] pt-4 text-xs leading-snug text-[var(--paper-muted)] lg:grid lg:grid-cols-3">
        <li :for={{step, i} <- Enum.with_index(@steps, 1)}>
          <strong class="text-[var(--paper-ink)]">{i}. {step["label"]}.</strong>
          <.step_detail id={step["id"]} d={@d} />
        </li>
      </ol>
      <button
        type="button"
        id="replay-flow"
        aria-label="Replay the animation of the change flow"
        class="team-replay-btn min-h-11 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--paper-accent)] mt-4 inline-flex items-center gap-1.5 rounded-full border border-[var(--paper-rule)] px-3 py-1 text-sm hover:bg-[var(--paper-bg)]"
        data-flow-replay
      >
        <.icon name="hero-arrow-path-micro" class="size-4" /> Replay
      </button>
    </figure>
    """
  end

  attr :id, :string, required: true
  attr :d, :map, required: true

  defp step_detail(%{id: "ci"} = assigns) do
    ~H"""
    CI runs.
    <.explain text="CI, continuous integration: robots that run every test and check on every PR. If anything fails, the PR can't merge." />
    """
  end

  defp step_detail(%{id: "check"} = assigns) do
    ~H"""
    Normal lane only: Gentry attacks it, and the five persona bots play it while Jev scores how each would have felt.
    """
  end

  defp step_detail(%{id: "founder_check"} = assigns) do
    ~H"""
    <em>Any founder reads the refinement and sends the card to Building. That is the OK to build.</em>
    """
  end

  defp step_detail(%{id: "ok_merge"} = assigns) do
    ~H"""
    <em>Any founder approves the PR on the board card. Admin-only fixes that a founder already OK'd merge when the checks pass.</em>
    """
  end

  defp step_detail(%{id: "ok_prod"} = assigns) do
    ~H"""
    <em>Normal lane only. {holder(@d)} pushes the production release.</em>
    """
  end

  defp step_detail(assigns) do
    assigns = assign(assigns, :text, Map.get(@flow_detail, assigns.id, ""))

    ~H"""
    {@text}
    """
  end

  attr :who, :string, default: nil

  defp step_owners(assigns) do
    assigns = assign(assigns, :owners, owners(assigns.who))

    ~H"""
    <%= case @owners do %>
      <% [] -> %>
        <span class="flex size-11 items-center justify-center rounded-full border-2 border-[var(--paper-rule)] bg-[var(--paper-margin)]">
          <.icon name="hero-cog-6-tooth" class="size-6 text-[var(--paper-muted)]" />
        </span>
      <% [one] -> %>
        <TeamArt.avatar id={one} class="size-11" />
      <% [one, two | _rest] -> %>
        <span class="relative block size-12">
          <TeamArt.avatar id={one} class="absolute left-0 top-0 size-8" />
          <TeamArt.avatar id={two} class="absolute bottom-0 right-0 size-8" />
        </span>
    <% end %>
    """
  end

  # ── 2. How we work ─────────────────────────────────────────────────────────

  attr :d, :map, required: true
  attr :live, :map, required: true

  defp how_section(assigns) do
    decisions = assigns.live.decisions
    all_days = decisions.by_date
    {by_date, _earlier} = TeamLiveNumbers.since_inception(all_days)

    assigns =
      assign(assigns,
        decisions: decisions,
        all_days: all_days,
        by_date: by_date,
        earlier: earlier_count(all_days, by_date),
        busiest: Enum.max_by(all_days, &(&1["count"] || 0), fn -> nil end),
        as_of: decisions.as_of
      )

    ~H"""
    <section id="how" class="team-section space-y-8" aria-labelledby="how-title" data-reveal>
      <.section_head id="how" title="2. How we work">
        A few simple rules keep the whole crew, founders and bots, pulling in the same direction.
      </.section_head>

      <div class="grid gap-4 lg:grid-cols-2">
        <article id="rule-decisions" class="team-card space-y-3 p-5">
          <h3 class="font-serif text-lg font-bold">1. Decisions are written down.</h3>
          <p class="text-sm leading-relaxed">
            Every decision goes into one log, <code>docs/decisions.md</code>
            in <code>tales-forge-docs</code>, with the date, the decision, why,
            and a link to the details. Changing a decision means adding a new entry, never editing history.
          </p>
          <p class="text-sm">
            <strong class="text-2xl text-[var(--paper-accent)]">{number(@decisions.total)}</strong>
            <strong>decisions in {count_word(length(@all_days))} days</strong>
            ({day_range(@all_days)}).
          </p>
          <p class="text-sm leading-relaxed text-[var(--paper-muted)]">
            Plus a decision queue of {number(get(@d, ["decisions", "queue", "total"]))} bigger questions
            ({number(get(@d, ["decisions", "queue", "open"]))} still open), and a future-ideas list
            ({number(get(@d, ["decisions", "future_ideas", "count"]))} ideas so far: <em>{ideas_text(@d)}</em>).
          </p>
          <h4 class="flex flex-wrap items-baseline justify-between gap-2 text-sm font-semibold">
            Decisions per day
            <span id="chart-decisions-window" class="text-xs font-normal text-[var(--paper-muted)]">
              {TeamLiveNumbers.window_label(:since_inception)}{if @earlier > 0,
                do: " (#{number(@earlier)} earlier)"}
            </span>
          </h4>
          <.column_chart
            id="chart-decisions"
            label="Decisions logged per day since 2026-10-07"
            items={
              Enum.map(
                @by_date,
                &%{
                  label: day_label(&1["date"], @as_of),
                  value: &1["count"],
                  display: number(&1["count"])
                }
              )
            }
          />
          <p :if={partial?(@by_date, @as_of)} class="text-[0.7rem] text-[var(--paper-muted)]">
            * partial day
          </p>
          <p :if={@busiest} class="text-xs italic text-[var(--paper-muted)]">
            {TeamPage.short_date(@busiest["date"])} was the big one: {number(@busiest["count"])} decisions in a day, mostly small, all written down.
          </p>
          <.group_source id="decisions-source" what="Decision numbers" group={@decisions} />
        </article>

        <div class="space-y-4">
          <article id="rule-docs" class="team-card space-y-2 p-5">
            <h3 class="font-serif text-lg font-bold">
              2. Docs go straight to main; code goes through PRs.
            </h3>
            <p class="text-sm leading-relaxed">
              Writing things down should be fast, so docs need no review step. Code always gets a PR and CI. Each change also gets a founder's OK,
              on the board card. Any founder approves PRs there, and {holder(@d)} pushes the normal-lane production releases.
            </p>
          </article>
          <article id="rule-code" class="team-card space-y-2 p-5">
            <h3 class="font-serif text-lg font-bold">4. Code that explains itself.</h3>
            <p class="text-sm leading-relaxed">
              “Humans may need to understand the code one day.” Every module says what it's for, every public function has docs and a type spec,
              and the tools check it all on every PR:
            </p>
            <ul class="team-bullets space-y-1 text-sm">
              <li>doctests <.explain text="examples in the docs that also run as tests" />;</li>
              <li>
                Dialyzer <.explain text="a type checker" />:
                <strong>{number(get(@d, ["code_standards", "dialyzer_warnings"]))}</strong>
                warnings;
              </li>
              <li>
                Credo <.explain text="a style checker" /> and the formatter;
              </li>
              <li>
                tests for every change, with coverage up from {pct(
                  get(@d, ["code_standards", "coverage_pct_2026_10_07"])
                )} to <strong>{pct(get(@d, ["code_standards", "coverage_pct"]))}</strong>
                in two days.
              </li>
            </ul>
          </article>
        </div>
      </div>

      <article id="rule-call-types" class="team-card space-y-4 p-5">
        <h3 class="font-serif text-lg font-bold">3. The call-type rule.</h3>
        <p class="text-sm leading-relaxed">
          Each piece of work in a turn uses the cheapest tool that can do it:
        </p>
        <div class="grid gap-3" role="table" aria-label="Call types">
          <div
            class="hidden grid-cols-4 gap-3 px-3 text-xs font-semibold uppercase tracking-wide text-[var(--paper-muted)] lg:grid"
            role="row"
          >
            <span role="columnheader">What goes in</span>
            <span role="columnheader">What comes out</span>
            <span role="columnheader">We use</span>
            <span role="columnheader">Why</span>
          </div>
          <div
            :for={row <- get(@d, ["call_types", "rows"]) || []}
            class={[
              "team-call-row grid gap-1 rounded-lg border-l-4 bg-[var(--paper-bg)] p-3 text-sm lg:grid-cols-4 lg:gap-3",
              "team-kind-#{call_kind(row["type"])}"
            ]}
            role="row"
          >
            <span role="cell"><span class="team-cell-label">In: </span>{io_label(row["input"])}</span>
            <span role="cell"><span class="team-cell-label">Out: </span>{io_label(row["output"])}</span>
            <strong role="cell" class="team-kind-text">{tool_label(row["type"])}</strong>
            <span role="cell" class="text-[var(--paper-muted)]">{row["cost"]}</span>
          </div>
        </div>
        <p class="text-xs leading-relaxed text-[var(--paper-muted)]">
          <em>Elixir</em>
          is the programming language the game is written in. <em>Jev</em>
          is TypeSafe's model that reads text and answers with typed data
          (a category plus a confidence), not prose. An <em>LLM</em>
          is a large language model, the kind of AI that writes text.
        </p>
        <p id="call-types-walkthrough-link" class="text-sm leading-relaxed">
          <strong>The call-type rule is the heart of the game engine, so it gets its own walkthrough below:</strong>
          <a
            href={"#" <> TeamCallTypes.anchor()}
            class="text-[var(--paper-accent)] underline underline-offset-2"
          >one turn, three call types</a>.
        </p>
      </article>

      <TeamCallTypes.walkthrough d={@d} />
    </section>
    """
  end

  # ── 3. Infrastructure ──────────────────────────────────────────────────────

  attr :d, :map, required: true

  defp infra_section(assigns) do
    ~H"""
    <section
      id="infrastructure"
      class="team-section space-y-8"
      aria-labelledby="infrastructure-title"
      data-reveal
    >
      <.section_head id="infrastructure" title="3. Infrastructure">
        The game is a small, sturdy web app. Here is what it runs on, in plain words.
      </.section_head>

      <ul id="stack" class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <.stack_item
          icon="hero-code-bracket"
          title="Elixir and Phoenix LiveView"
          version={stack(@d, ["language", "web"])}
        >
          The language and web framework. LiveView keeps the page live over one connection, so the story updates without page reloads.
        </.stack_item>
        <.stack_item icon="hero-circle-stack" title="Ecto and Postgres" version={stack(@d, ["db"])}>
          The database layer and the database: sessions, characters, turns and costs.
        </.stack_item>
        <.stack_item icon="hero-queue-list" title="Oban" version={stack(@d, ["jobs"])}>
          Background jobs, such as running a turn or a playtest, so nothing blocks the page.
        </.stack_item>
        <.stack_item icon="hero-magnifying-glass" title="TypeSafe Jev" version={stack(@d, ["jev"])}>
          Reads what the player meant (intent), flags tricks (safety) and scores playtests.
        </.stack_item>
        <.stack_item icon="hero-sparkles" title="Grok (xAI)" version={stack(@d, ["gm_model"])}>
          The Game Master model. It writes the story, and only the story.
        </.stack_item>
        <.stack_item icon="hero-cloud" title="Fly.io, Stockholm">
          Two apps: <code>{get(@d, ["infrastructure", "apps", 0, "name"]) || "tales-forge"}</code>
          (production) and
          <code>{get(@d, ["infrastructure", "apps", 1, "name"]) || "tales-forge-playtest"}</code>
          (playtest). The live feed on /team shows which commit each app runs.
        </.stack_item>
      </ul>

      <div class="grid gap-3 lg:grid-cols-4">
        <div class="team-card space-y-1 p-4">
          <h3 class="flex items-center gap-2 font-semibold">
            <.icon name="hero-key" class="size-5 text-[var(--paper-accent)]" /> One way in
          </h3>
          <p class="text-sm">
            “Sign in with GitHub”, only for members of the founders' team, on every page of both apps.
          </p>
        </div>
        <div class="team-card space-y-1 p-4">
          <h3 class="flex items-center gap-2 font-semibold">
            <.icon name="hero-lock-closed" class="size-5 text-[var(--paper-accent)]" /> Separate keys
          </h3>
          <p class="text-sm">
            Production and playtest have their own AI keys, so bot testing never mixes with real play in the bills.
            The keys live in Fly's secret store; nobody pastes them anywhere.
          </p>
        </div>
        <div class="team-card space-y-1 p-4">
          <h3 class="flex items-center gap-2 font-semibold">
            <.icon name="hero-banknotes" class="size-5 text-[var(--paper-accent)]" /> Costs pages
          </h3>
          <p class="text-sm">
            <.link href={~p"/admin/operate/costs"} class="underline">/admin/operate/costs</.link>
            shows AI spend per day and month. Production shows everything, with playtest's costs read live from the playtest app.
          </p>
        </div>
        <details id="hosting" class="team-card group p-4">
          <summary class="cursor-pointer list-none space-y-1">
            <span class="block font-serif text-3xl font-bold text-[var(--paper-accent)]">
              {usd(get(@d, ["infrastructure", "hosting_total_usd_per_month"]))}<span class="text-base font-normal">/month</span>
            </span>
            <span class="block text-sm">About {usd(
              get(@d, ["infrastructure", "hosting_total_usd_per_month"])
            )}/month for hosting and the domain, before AI usage.</span>
            <span class="text-xs text-[var(--paper-accent)] underline group-open:hidden">Show the parts</span>
          </summary>
          <ul class="mt-3 space-y-1 text-xs">
            <li
              :for={item <- get(@d, ["infrastructure", "hosting_usd_per_month"]) || []}
              class="flex justify-between gap-2"
            >
              <span>{item["item"]}</span>
              <span class="shrink-0 font-semibold tabular-nums">{if item["approx"], do: "~"}{usd(
                item["usd"]
              )}</span>
            </li>
          </ul>
        </details>
      </div>

      <.architecture d={@d} />
    </section>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :version, :string, default: nil
  slot :inner_block, required: true

  defp stack_item(assigns) do
    ~H"""
    <li class="team-card flex gap-3 p-4">
      <span class="flex size-10 shrink-0 items-center justify-center rounded-full bg-[var(--paper-margin)]">
        <.icon name={@icon} class="size-5 text-[var(--paper-accent)]" />
      </span>
      <div class="min-w-0 space-y-1">
        <h3 class="font-semibold">{@title}</h3>
        <p class="text-sm leading-snug">{render_slot(@inner_block)}</p>
        <p :if={@version} class="break-words text-[0.7rem] text-[var(--paper-muted)]">{@version}</p>
      </div>
    </li>
    """
  end

  attr :d, :map, required: true

  defp architecture(assigns) do
    ~H"""
    <figure id="architecture" class="team-card space-y-4 p-4 sm:p-6">
      <h3 class="font-serif text-xl font-bold">How a turn works</h3>
      <ol class="flex flex-col items-stretch gap-2 lg:flex-row lg:items-start">
        <%= for {node, i} <- Enum.with_index(get(@d, ["infrastructure", "architecture_nodes"]) || []) do %>
          <li :if={i > 0} class="flex justify-center lg:mt-6 lg:items-center" aria-hidden="true">
            <.icon name="hero-arrow-down" class="size-5 text-[var(--paper-muted)] lg:hidden" />
            <.icon name="hero-arrow-right" class="hidden size-5 text-[var(--paper-muted)] lg:block" />
          </li>
          <li class={[
            "team-arch-node flex-1 rounded-lg border-2 p-3 text-center",
            "team-kind-#{node_kind(node)}"
          ]}>
            <span class="team-kind-text mx-auto mb-1 flex size-9 items-center justify-center">
              <.node_icon node={node} />
            </span>
            <p class="text-sm font-semibold leading-tight">{node}</p>
            <p :if={node_note(node, @d)} class="mt-1 text-xs italic text-[var(--paper-muted)]">
              {node_note(node, @d)}
            </p>
          </li>
        <% end %>
      </ol>
      <figcaption class="space-y-2">
        <p class="font-serif text-lg">The rules decide what happens. The AI only tells the story.</p>
        <ul class="flex flex-wrap gap-x-4 gap-y-1 text-xs">
          <li class="team-kind-elixir flex items-center gap-1.5">
            <span class="team-swatch"></span> Elixir: exact, free, instant
          </li>
          <li class="team-kind-jev flex items-center gap-1.5">
            <span class="team-swatch"></span> Jev: fast and cheap
          </li>
          <li class="team-kind-llm flex items-center gap-1.5">
            <span class="team-swatch"></span> LLM: slowest and most expensive, so it goes last
          </li>
        </ul>
        <p id="intent-status-note" class="text-xs text-[var(--paper-muted)]">
          <.intent_status d={@d} />
        </p>
      </figcaption>
    </figure>
    """
  end

  attr :d, :map, required: true

  defp intent_status(assigns) do
    assigns = assign(assigns, :status, get(assigns.d, ["intent_status"]))

    ~H"""
    <%= if @status && @status["production"] == "on" && @status["playtest"] == "on" do %>
      Honesty note: Jev intent is <strong>on in both apps</strong>
      since {date_label(@status["since"])} (playtest {@status["playtest_release"]}, production {@status[
        "production_release"
      ]}): it reads every new turn,
      and the old keyword path only takes over on an error or timeout. Before that it ran in
      <em>shadow</em>
      on playtest
      (it read every turn, but the old path still decided) and was off in production.
    <% else %>
      Honesty note: today Jev intent runs in <em>shadow</em>
      on playtest (it reads every turn, but the old path still decides)
      and is off in production.
    <% end %>
    """
  end

  attr :node, :string, required: true

  defp node_icon(assigns) do
    ~H"""
    <%= case node_icon_name(@node) do %>
      <% :quill -> %>
        <TeamArt.quill class="size-7" />
      <% name -> %>
        <.icon name={name} class="size-7" />
    <% end %>
    """
  end

  # ── 4. Playtests ───────────────────────────────────────────────────────────

  attr :d, :map, required: true
  attr :live, :map, required: true

  defp playtests_section(assigns) do
    ~H"""
    <section
      id="playtests"
      class="team-section space-y-10"
      aria-labelledby="playtests-title"
      data-reveal
    >
      <.section_head id="playtests" title="4. Playtests">
        We can't hire a hundred players yet, so we built {count_word(length(personas(@d)))} pretend ones. Each persona bot plays the game the way
        a real kind of player would, and Jev reads every session and asks: how would <em>this</em>
        player have felt?
      </.section_head>

      <ul id="persona-cards" class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <li
          :for={p <- personas(@d)}
          id={"persona-#{p["id"]}"}
          class={["team-card flex flex-col gap-2 p-4", p["id"] == "ronny" && "team-anti"]}
        >
          <div class="flex items-center gap-3">
            <TeamArt.persona_token id={p["id"]} class="size-12" />
            <div>
              <h3 class="font-serif text-lg font-bold leading-tight">{p["name"]}</h3>
              <p class="text-xs font-semibold text-[var(--paper-accent)]">{p["style"]}</p>
            </div>
          </div>
          <p class="text-sm leading-snug">{p["line"]}</p>
          <p class="mt-auto text-[0.7rem] text-[var(--paper-muted)]">
            Test character: {p["character"]}
          </p>
        </li>
      </ul>

      <div class="grid gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(0,2fr)]">
        <div class="space-y-3">
          <h3 class="font-serif text-xl font-bold">How scoring works</h3>
          <p class="text-sm leading-relaxed">
            Jev gives each turn a score from 1 (frustrated) to 5 (delighted) for that persona, plus how sure it is.
            The headline is a <strong>confidence-weighted average</strong>: every turn counts, and a turn counts more when Jev has more confidence in it.
            We show it as “{score_example(@d)}”, so you can see both the score and how much to trust it.
          </p>
          <h3 class="pt-2 font-serif text-xl font-bold">What changed</h3>
          <ul id="highlights" class="team-bullets space-y-1.5 text-sm">
            <li :for={h <- Enum.take(get(@d, ["playtest_series", "highlights"]) || [], 4)}>
              <.highlight text={h} />
            </li>
          </ul>
        </div>
        <div class="team-card space-y-3 p-4">
          <h3 class="font-semibold">Persona scores over time</h3>
          <.persona_panels
            id="chart-personas"
            personas={personas(@d)}
            series={get(@d, ["playtest_series", "series"]) || []}
          />
          <p class="text-xs italic text-[var(--paper-muted)]">
            Small batches, so small moves are noise. The clear win is Hawk: once the game gave him a real antagonist, his scores came up.
          </p>
          <.full_batch batch={get(@d, ["playtest_series", "full_batch"])} personas={personas(@d)} />
          <p
            id="personas-series-source"
            class="text-xs text-[var(--paper-muted)]"
            data-source="fallback"
          >
            Batch series: as of {TeamPage.date_label(get(@d, ["playtest_series", "as_of"]))}, from the batch analyses.
          </p>
        </div>
      </div>

      <.persona_scores_now scores={@live.persona_scores} personas={personas(@d)} />

      <.shadow_test d={@d} latency={@live.intent_latency} />
      <.eval_set d={@d} />
      <.gentry d={@d} />
    </section>
    """
  end

  attr :text, :string, required: true

  defp highlight(assigns) do
    assigns = assign(assigns, :parts, split_highlight(assigns.text))

    ~H"""
    <%= case @parts do %>
      <% {before, value, rest} -> %>
        {before} → <strong>{value}</strong>{rest}
      <% text -> %>
        {text}
    <% end %>
    """
  end

  attr :batch, :map, default: nil
  attr :personas, :list, required: true

  defp full_batch(assigns) do
    ~H"""
    <div
      :if={@batch}
      id="full-batch"
      class="rounded-lg border border-dashed border-[var(--paper-rule)] p-3 text-xs"
    >
      <p class="font-semibold">{@batch["label"]}</p>
      <p class="text-[var(--paper-muted)]">{@batch["status"]}</p>
      <ul class="mt-2 flex flex-wrap gap-x-4 gap-y-1">
        <li :for={p <- @personas}>
          {p["name"]}:
          <span class="italic text-[var(--paper-muted)]">{score(get(@batch, ["weighted", p["id"]]))}</span>
        </li>
        <li>
          Runs:
          <span class="italic text-[var(--paper-muted)]">{number(@batch["completed_runs"])}</span>
        </li>
        <li>Cost: <span class="italic text-[var(--paper-muted)]">{usd(@batch["cost_usd"])}</span></li>
      </ul>
    </div>
    """
  end

  attr :scores, :map, required: true, doc: "`TalesForgeWeb.TeamLiveNumbers.persona_scores/2`"
  attr :personas, :list, required: true

  # The Jev score per persona now: live over every scored run here since
  # 2026-10-07 (playtest), else the last batch (labelled "as of").
  defp persona_scores_now(assigns) do
    ~H"""
    <div id="persona-scores-now" class="team-card space-y-3 p-4">
      <h3 class="font-semibold">
        Jev score per persona
        <span id="persona-scores-window" class="text-xs font-normal text-[var(--paper-muted)]">
          {if @scores.source == :live,
            do: TeamLiveNumbers.window_label(:since_inception),
            else: "last batch"}
        </span>
      </h3>
      <ul class="grid grid-cols-2 gap-2 text-sm sm:grid-cols-5">
        <li :for={p <- @personas} id={"persona-now-#{p["id"]}"} class="min-w-0">
          <span class="font-semibold">{p["name"]}</span>
          <span class="block">
            {score_text(get_in(@scores.by_persona, [p["id"], :score]))}<span
              :if={get_in(@scores.by_persona, [p["id"], :unsure_pct])}
              class="text-xs text-[var(--paper-muted)]"
            > · confident {100 - get_in(@scores.by_persona, [p["id"], :unsure_pct])}%</span>
          </span>
        </li>
      </ul>
      <p :if={@scores.source == :live} class="text-xs text-[var(--paper-muted)]">
        {number(@scores.runs)} scored runs on {app_word()}.
      </p>
      <p :if={@scores.source != :live} id="persona-scores-live-link" class="text-xs">
        Playtest runs live on playtest. Live scores per run:
        <a
          href={TalesForge.AppRole.link(:playtest_runs, "/admin/play/runs")}
          data-cross-app
          class="font-semibold text-[var(--paper-accent)] underline"
        >
          playtest runs{if TalesForge.AppRole.here?(:playtest_runs), do: "", else: " ↗"}
        </a>
      </p>
      <.group_source id="persona-scores-source" what="Persona scores" group={@scores} />
    </div>
    """
  end

  defp score_text(nil), do: TeamPage.not_measured()
  defp score_text(score), do: "#{:erlang.float_to_binary(score * 1.0, decimals: 2)}/5"

  attr :d, :map, required: true

  attr :latency, :map, required: true

  defp shadow_test(assigns) do
    assigns =
      assign(assigns,
        s: get(assigns.d, ["intent_shadow"]) || %{},
        c: get(assigns.d, ["intent_compare"])
      )

    ~H"""
    <div id="shadow-test" class="space-y-5">
      <h3 class="font-serif text-2xl font-bold">Jev intent: the shadow test</h3>
      <p class="max-w-3xl leading-relaxed text-[var(--paper-muted)]">
        We replaced a keyword guesser with Jev for working out what the player meant. Before switching, we ran Jev in <em>shadow</em>:
        it read every turn on playtest but didn't change anything, so we could compare.
      </p>
      <p id="shadow-source" class="text-xs text-[var(--paper-muted)]" data-source="fallback">
        Shadow test numbers: as of {TeamPage.date_label(@s["as_of"])} (a one-off test, 2026-10-08 to 2026-10-09).
      </p>
      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <.stat id="shadow-reads" value={number(@s["reads"])} label="turns read" />
        <.stat id="shadow-latency" value={ms(@s["p50_ms"])} label={"median, #{ms(@s["p95_ms"])} p95"}>
          p95: 95% of reads were faster than this
        </.stat>
        <.stat
          id="shadow-within"
          value={within_text(@s["within_timeout"], @s["reads"])}
          label={"inside the #{seconds(@s["timeout_ms"])} limit"}
        />
        <.stat id="shadow-cost" value={usd(@s["cost_usd"])} label="total">
          about {usd(@s["cost_per_turn_usd"])} a turn
        </.stat>
        <.stat
          id="shadow-diff"
          value={pct(get(@s, ["material_difference", "pct"]))}
          label="of turns read materially differently from today"
        >
          In the examples we checked, Jev was the one that got it right.
        </.stat>
      </div>

      <blockquote class="team-callout space-y-1 p-4 text-sm">
        <p>
          Player:
          <em>“Good folk, the Light teaches that even the fiercest storm may be calmed with patient words…”</em>
        </p>
        <p>
          Today's guesser: <strong>combat</strong>. Jev: <strong>talk to the innkeeper</strong>.
          <span class="text-[var(--team-jev)]">✔ Jev</span>
        </p>
      </blockquote>

      <div class="grid gap-4 lg:grid-cols-2">
        <div class="team-card space-y-3 p-4">
          <h4 class="font-semibold">
            Intent latency
            <span id="chart-latency-window" class="text-xs font-normal text-[var(--paper-muted)]">
              {if @latency.source == :live,
                do: TeamLiveNumbers.window_label(:last_7_days),
                else: "shadow test"}
            </span>
          </h4>
          <.latency_chart
            id="chart-latency"
            p50={@latency.p50_ms}
            p95={@latency.p95_ms}
            max={@latency.max_ms}
            timeout={@latency.timeout_ms || @s["timeout_ms"]}
          />
          <p :if={@latency.source == :live} class="text-xs text-[var(--paper-muted)]">
            {number(@latency.reads)} Jev intent reads on {app_word()}.
          </p>
          <p id="latency-per-app" class="text-xs">
            Each app's latency, live:
            <a
              href="/admin/operate/costs#costs-intent-latency"
              class="font-semibold text-[var(--paper-accent)] underline"
            >
              Admin › Operate › Costs
            </a>
          </p>
          <.group_source id="latency-source" what="Latency" group={@latency} />
        </div>
        <div class="team-card space-y-3 p-4">
          <h4 class="font-semibold">Agreement with today's path</h4>
          <.bar_list
            id="chart-agreement"
            label="Agreement with today's intent path, percent"
            max={100}
            color="var(--team-jev)"
            items={
              for {k, v} <- agreement(@s),
                  do: %{label: String.capitalize(k), value: v, display: pct(v)}
            }
          />
          <p class="text-xs italic text-[var(--paper-muted)]">
            Low agreement mostly means the old guesser was wrong, not Jev.
          </p>
        </div>
      </div>

      <div :if={@c} id="intent-compare" class="team-card space-y-3 p-4">
        <h4 class="font-semibold">Then on versus off ({date_label(@c["as_of"])})</h4>
        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <.stat
            id="compare-score"
            value={number(@c["jev_score_on"])}
            label={"Jev score with intent on, #{number(@c["jev_score_off"])} off"}
          >
            a tie: the difference is inside the noise
          </.stat>
          <.stat
            id="compare-p95"
            value={"#{ms(@c["intent_p95_ms_off"])} → #{ms(@c["intent_p95_ms_on"])}"}
            label="intent p95, off → on"
          />
          <.stat
            id="compare-within"
            value={pct(@c["within_timeout_pct_on"])}
            label={"of reads within #{seconds(@c["timeout_ms"])} with intent on"}
          />
          <.stat id="compare-cost" value={usd(@c["cost_usd"])} label="for the whole comparison">
            {number(@c["scored_runs_per_arm"])} scored runs per arm
          </.stat>
        </div>
      </div>
    </div>
    """
  end

  attr :d, :map, required: true

  defp eval_set(assigns) do
    assigns = assign(assigns, :e, get(assigns.d, ["intent_eval_set"]) || %{})

    ~H"""
    <div id="eval-set" class="space-y-5">
      <h3 class="font-serif text-2xl font-bold">The eval set</h3>
      <p id="eval-source" class="text-xs text-[var(--paper-muted)]" data-source="fallback">
        Eval numbers: as of {TeamPage.date_label(@e["as_of"])} (the eval runs offline, so there is no live source yet).
      </p>
      <p class="max-w-3xl leading-relaxed text-[var(--paper-muted)]">
        To trust Jev, we built an exam for it: {number(@e["total"])} real and hand-written player lines with the right answers,
        split so we tune on one part and keep the other part unseen until the end.
      </p>
      <ul class="team-bullets grid gap-2 text-sm lg:grid-cols-2">
        <li>
          <strong>{number(@e["total"])}</strong>
          items: <strong>{number(@e["tune"])}</strong>
          tune, <strong>{number(@e["holdout"])}</strong>
          held out <.explain text="never looked at while tuning, so the final score is honest" />.
        </li>
        <li>
          <strong>{number(@e["real_playtest"])}</strong>
          from real playtests, <strong>{number(@e["handwritten"])}</strong>
          written by hand,
          including <strong>{number(get(@e, ["attack_items", "total"]))}</strong>
          attacks (injections, jailbreaks, nefarious requests).
        </li>
        <li>
          On the tune split after tuning: action right <strong>{pct(get(@e, ["tune_results_after_tuning", "action_accuracy_pct"]))}</strong>,
          attacks caught <strong>{get(@e, ["tune_results_after_tuning", "safety_recall"]) || TeamPage.not_measured()}</strong>,
          false alarms <strong>{get(@e, ["tune_results_after_tuning", "false_positives"]) || TeamPage.not_measured()}</strong>.
        </li>
        <li id="eval-holdout">
          Held-out result: <strong class="italic">{holdout_text(@e["holdout_results"])}</strong>. It runs once, on frozen settings, before production.
        </li>
      </ul>
      <div class="team-card space-y-3 p-4">
        <h4 class="font-semibold">What's in the exam</h4>
        <.stacked_bar id="chart-eval" label="Eval set items by category" parts={eval_parts(@e)} />
      </div>
    </div>
    """
  end

  attr :d, :map, required: true

  defp gentry(assigns) do
    assigns = assign(assigns, :g, get(assigns.d, ["gentry_findings"]) || %{})

    ~H"""
    <div id="gentry" class="space-y-5">
      <div class="flex items-center gap-3">
        <TeamArt.avatar id="gentry" class="size-12" label="Gentry" />
        <h3 class="font-serif text-2xl font-bold">Gentry's findings so far</h3>
      </div>
      <p class="max-w-3xl leading-relaxed text-[var(--paper-muted)]">
        Gentry started on playtest this week. The first catch was not an exploit but something every phone player would have hit.
      </p>
      <div class="grid gap-4 lg:grid-cols-2">
        <div class="team-card space-y-2 p-4">
          <h4 class="font-semibold">Fixed</h4>
          <ul class="team-bullets space-y-1 text-sm">
            <li :for={f <- @g["fixed_in_pr89"] || []}>{f}</li>
          </ul>
        </div>
        <div class="team-card space-y-2 p-4">
          <h4 class="font-semibold">Also noted</h4>
          <ul class="team-bullets space-y-1 text-sm">
            <li :for={f <- @g["follow_ups_noted"] || []}>{f}</li>
          </ul>
        </div>
      </div>
      <.hostile_play results={@g["hostile_play_results"]} />
    </div>
    """
  end

  attr :results, :map, default: nil

  defp hostile_play(%{results: %{"runs" => runs}} = assigns) when is_list(runs) do
    ~H"""
    <div id="hostile-play" class="space-y-3">
      <h4 class="font-serif text-xl font-bold">Hostile play</h4>
      <div class="grid gap-4 lg:grid-cols-2">
        <article
          :for={run <- @results["runs"]}
          id={"hostile-#{run["id"]}"}
          class="team-card space-y-2 p-4"
        >
          <p class="flex flex-wrap items-baseline justify-between gap-2">
            <span class="font-semibold">{run["label"]}</span>
            <span class="text-xs text-[var(--paper-muted)]">{run["at"] || ""}</span>
          </p>
          <p class="text-sm">{attack_count(run)}:</p>
          <ul class="team-bullets space-y-1 text-sm">
            <li :for={a <- run["attacks"] || []}>{a}</li>
          </ul>
          <p class="team-ok rounded px-2 py-1 text-sm font-semibold">{run["result"]}</p>
          <ul :if={(run["issues"] || []) != []} class="space-y-1 text-sm">
            <li :for={i <- run["issues"]} class="team-warn rounded px-2 py-1">⚠ {i}</li>
          </ul>
        </article>
      </div>
      <p class="text-sm">
        AI turns took <strong>{range(@results, "ai_turn_s", "s")}</strong>; pages loaded in <strong>{range(@results, "page_load_s", "s")}</strong>.
      </p>
      <p :if={@results["summary"]} class="text-sm text-[var(--paper-muted)]">{@results["summary"]}</p>
    </div>
    """
  end

  defp hostile_play(assigns) do
    ~H"""
    <p
      id="hostile-play"
      class="rounded-lg border border-dashed border-[var(--paper-rule)] p-3 text-sm italic text-[var(--paper-muted)]"
    >
      Hostile-play results (injections, fake GM notes, false claims) will appear here once Gentry has logged them.
    </p>
    """
  end

  # ── 5. Pace and cost ───────────────────────────────────────────────────────

  attr :d, :map, required: true
  attr :pace, :map, required: true, doc: "`TalesForge.TeamPace.current/0`"
  attr :live, :map, required: true, doc: "`TalesForgeWeb.TeamLiveNumbers.all/3`"

  defp pace_section(assigns) do
    {current, earlier} = split_prs_since_inception(assigns.pace)
    {commit_days, _earlier} = TeamLiveNumbers.since_inception(assigns.pace.commits_by_day)
    as_of = assigns.pace.as_of

    assigns =
      assign(assigns,
        current: current,
        earlier: earlier,
        commit_days: commit_days,
        busiest: Enum.max_by(current, &(&1["created"] || 0), fn -> nil end),
        as_of: as_of,
        tests: assigns.live.tests,
        decisions: assigns.live.decisions,
        costs: assigns.live.costs
      )

    ~H"""
    <section id="pace" class="team-section space-y-8" aria-labelledby="pace-title" data-reveal>
      <.section_head id="pace" title="5. Pace and cost">
        Bots are fast. These numbers show how fast, and what it cost.
      </.section_head>

      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <.stat id="pace-prs" value={number(@pace.prs_total)} label="PRs">
          <span id="pace-prs-merged">{number(@pace.prs_merged)}</span>
          merged, <span id="pace-prs-open">{number(@pace.prs_open)}</span>
          open
        </.stat>
        <.stat
          id="pace-commits"
          value={number(@pace.commits)}
          label="commits on the game's main branch"
        />
        <.stat
          id="pace-tests"
          value={"#{number(@tests.tests)} + #{number(@tests.doctests)}"}
          label="tests + doctests"
        >
          {number(@tests.failures)} failing, {pct(@tests.coverage_pct)} coverage
        </.stat>
        <.stat
          id="pace-decisions"
          value={number(@decisions.total)}
          label="decisions logged"
        />
        <div class="space-y-0.5 sm:col-span-2 lg:col-span-4">
          <.pace_source id="pace-source" pace={@pace} />
          <.group_source id="pace-source-tests" what="Tests" group={@tests} />
          <.group_source id="pace-source-decisions" what="Decisions" group={@decisions} />
        </div>
      </div>

      <div class="grid gap-4 lg:grid-cols-2">
        <div class="team-card space-y-3 p-4">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h3 class="font-semibold">
              PRs per day
              <span id="chart-prs-window" class="text-xs font-normal text-[var(--paper-muted)]">
                {TeamLiveNumbers.window_label(:since_inception)}
              </span>
            </h3>
            <span
              :if={@earlier}
              id="prs-earlier-chip"
              class="rounded-full bg-[var(--paper-margin)] px-2.5 py-0.5 text-xs font-semibold"
            >
              {@earlier}
            </span>
          </div>
          <.paired_chart
            id="chart-prs"
            label="Pull requests created and merged per day since 2026-10-07"
            legend={["created", "merged"]}
            items={
              Enum.map(
                @current,
                &%{label: day_label(&1["date"], @as_of), a: &1["created"], b: &1["merged"]}
              )
            }
          />
          <p :if={partial?(@current, @as_of)} class="text-[0.7rem] text-[var(--paper-muted)]">
            * partial day
          </p>
          <p :if={@busiest} class="text-xs italic text-[var(--paper-muted)]">
            {number(@busiest["created"])} PRs opened on {long_day(@busiest["date"])} alone.
          </p>
        </div>
        <div class="space-y-4">
          <div class="team-card space-y-3 p-4">
            <h3 class="font-semibold">
              Commits per day on main
              <span id="chart-commits-window" class="text-xs font-normal text-[var(--paper-muted)]">
                {TeamLiveNumbers.window_label(:since_inception)}
              </span>
            </h3>
            <.heat_strip
              id="chart-commits"
              label="Commits per day on the game's main branch since 2026-10-07"
              days={@commit_days}
            />
          </div>
          <div id="ai-spend" class="team-callout space-y-2 p-4 text-sm leading-relaxed">
            <p>
              Letting bots play hundreds of sessions sounds expensive. It isn't: the playtest batches documented so far cost about
              <strong>{usd(get(@d, ["ai_spend", "documented_total_usd"]))}</strong>
              in total, roughly <strong>{per_run(@d)}</strong>
              per 10-turn run.
              Playtest has a daily cap of <strong>{usd(get(@d, ["ai_spend", "playtest_day_cap_usd"]))}</strong>, and we haven't come close.
            </p>
          </div>
        </div>
      </div>

      <div class="team-card space-y-3 p-4">
        <h3 class="font-semibold">
          AI spend per day
          <span id="chart-spend-days-window" class="text-xs font-normal text-[var(--paper-muted)]">
            {TeamLiveNumbers.window_label(:last_7_days)}
          </span>
        </h3>
        <.bar_list
          id="chart-spend-days"
          label="AI spend per day, last 7 days, USD"
          items={
            for day <- @costs.days,
                do: %{
                  label: TeamPage.short_date(day["date"]),
                  value: day["usd"],
                  display: usd(day["usd"])
                }
          }
        />
        <p class="text-xs text-[var(--paper-muted)]">
          {usd(@costs.total_usd)} in the last 7 days{if @costs.source == :live,
            do: " on " <> app_word(),
            else: " of playtest runs"}. Today is a partial day.
        </p>
        <.group_source id="spend-days-source" what="Spend per day" group={@costs} />
      </div>

      <div class="team-card space-y-3 p-4">
        <h3 class="font-semibold">Where the AI money went</h3>
        <.bar_list
          id="chart-spend"
          label="Documented AI spend per batch, USD"
          items={
            for i <- get(@d, ["ai_spend", "documented_items_usd"]) || [],
                do: %{label: i["item"], value: i["usd"], display: usd(i["usd"])}
          }
        />
        <p id="spend-gaps" class="text-xs text-[var(--paper-muted)]">
          Not shown: {Enum.join(get(@d, ["ai_spend", "gaps"]) || [], "; ")}.
        </p>
        <p id="spend-batches-source" class="text-xs text-[var(--paper-muted)]" data-source="fallback">
          Per-batch spend: as of {TeamPage.date_label(get(@d, ["ai_spend", "as_of"]))}, from the analysis docs (no live source per batch).
        </p>
      </div>
    </section>
    """
  end

  # ── 6. One shared board: TalesForgeWeb.TeamBoard ─────────────────────────

  # ── 7. Together ────────────────────────────────────────────────────────────

  attr :d, :map, required: true

  defp together_section(assigns) do
    assigns =
      assign(assigns,
        survey_url: AppRole.link(:surveys, "/admin/founders/survey"),
        playtest_url: AppRole.base_url(:playtest)
      )

    ~H"""
    <section id="together" class="team-section space-y-8" aria-labelledby="together-title" data-reveal>
      <.section_head id="together" title="7. Where we go from here, together">
        Several founders already add, vote, comment and approve on the shared board. The best part is still ahead,
        and it gets better with every founder who joins in. Together we can make something awesome.
      </.section_head>
      <ul id="involve" class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <.involve
          id="involve-board"
          icon="hero-view-columns"
          title="Start on the board."
          href="/team#idea-board"
          link="The idea board"
        >
          The idea board on /team is the first place to take part. Add a card in Ideas, vote on the others and comment.
          A card with an upvote goes to Case for refining.
        </.involve>
        <.involve
          id="involve-approve"
          icon="hero-key"
          title="Hold the approval key yourself."
          href="/team#idea-board"
          link="Approve on the board"
        >
          You approve on the board today. Send a card to Building to give the founder OK, and approve its PR on the card.
        </.involve>
        <.involve
          icon="hero-clipboard-document-check"
          title="Answer the surveys."
          href={@survey_url}
          link="Open the survey"
        >
          Founder surveys are on production at <code>/admin/founders/survey</code>. Your answers set how the game reads players and what we test for.
        </.involve>
        <.involve
          icon="hero-puzzle-piece"
          title="Play the playtest."
          href={@playtest_url}
          link={URI.parse(@playtest_url).host}
        >
          Sign in with GitHub and play a few turns. Your sessions show up next to the persona bots'.
        </.involve>
        <.involve
          id="involve-archive"
          icon="hero-archive-box"
          title="Read the idea archive."
          href="/admin/docs/future-ideas.md"
          link="docs/future-ideas.md"
        >
          The future-ideas list keeps the ideas from before the board. Put a new idea on the board.
        </.involve>
      </ul>
      <div class="team-callout flex flex-col items-center gap-3 p-6 text-center sm:flex-row sm:text-left">
        <TeamArt.seal class="size-14 shrink-0" />
        <p class="font-serif text-lg leading-relaxed sm:text-xl">
          A founder's yes on every change, {count_word(bot_count(@d))} bots that never get tired, a paper trail for every decision,
          and room at the table for all of us. Let's build it together.
        </p>
      </div>
    </section>
    """
  end

  attr :id, :string, default: nil
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :href, :string, default: nil
  attr :link, :string, default: nil
  slot :inner_block, required: true

  defp involve(assigns) do
    ~H"""
    <li id={@id} class="team-card flex flex-col gap-2 p-4">
      <.icon name={@icon} class="size-7 text-[var(--paper-accent)]" />
      <h3 class="font-semibold">{@title}</h3>
      <p class="flex-1 text-sm leading-snug">{render_slot(@inner_block)}</p>
      <a :if={@href} href={@href} class="text-sm font-semibold text-[var(--paper-accent)] underline">{@link} →</a>
    </li>
    """
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp members(d), do: TeamPage.members(d)
  defp find_member(members, id), do: Enum.find(members || [], %{}, &(&1["id"] == id))
  defp personas(d), do: get(d, ["personas", "items"]) || []
  defp bot_count(d), do: TeamPage.bot_count(d)
  defp holder(d), do: TeamPage.approval_holder(d)

  # The caption under a founder's-OK seal in the change flow.
  defp seal_caption("ok_prod", d), do: "Release: #{holder(d)} pushes it."
  defp seal_caption(_id, _d), do: "Any founder, on the board."

  defp kind_label(%{"kind" => "humans"}), do: "humans"
  defp kind_label(%{"kind" => kind}), do: kind

  defp tests_label(tests) do
    if tests.failures == 0,
      do: "automated tests, all passing",
      else: "automated tests"
  end

  defp tests_total(%{tests: t, doctests: d}) when is_integer(t) and is_integer(d), do: t + d
  defp tests_total(%{tests: t}), do: t

  # The October median, rounded to the nearest 5 minutes ("about 15").
  defp median_minutes(d) do
    case get(d, ["pace", "median_hours_open_to_merge_oct"]) do
      h when is_number(h) -> number(round(h * 60 / 5) * 5)
      _missing -> TeamPage.not_measured()
    end
  end

  @doc false
  @spec owners(String.t() | nil) :: [String.t()]
  def owners(who) when is_binary(who) do
    who = String.downcase(who)

    for {id, word} <- [
          {"founders", "founder"},
          {"case", "case"},
          {"bobby", "bobby"},
          {"gentry", "gentry"}
        ],
        String.contains?(who, word),
        do: id
  end

  def owners(_who), do: []

  defp owner_text(who, d) when is_binary(who) do
    names = Map.new(members(d), &{&1["id"], &1["name"]})

    who
    |> String.split(~r/,\s*/)
    |> Enum.map_join(" + ", &Map.get(names, &1, &1))
  end

  defp owner_text(_who, _d), do: ""

  defp day_label(date, as_of) do
    if date == as_of, do: "#{TeamPage.short_date(date)}*", else: TeamPage.short_date(date)
  end

  defp partial?(days, as_of), do: Enum.any?(days, &(&1["date"] == as_of))

  defp long_day(iso) do
    case Date.from_iso8601(iso || "") do
      {:ok, date} -> Calendar.strftime(date, "%-d %B")
      _error -> TeamPage.not_measured()
    end
  end

  defp day_range([]), do: TeamPage.not_measured()

  defp day_range(days) do
    first = days |> List.first() |> Map.get("date")
    last = days |> List.last() |> Map.get("date")

    with {:ok, a} <- Date.from_iso8601(first || ""),
         {:ok, b} <- Date.from_iso8601(last || "") do
      "#{a.day}–#{Calendar.strftime(b, "%-d %b")}"
    else
      _error -> TeamPage.not_measured()
    end
  end

  defp ideas_text(d) do
    case get(d, ["decisions", "future_ideas", "items"]) do
      [_ | _] = items -> items |> Enum.map(&ideas_item/1) |> TeamPage.and_list()
      _none -> TeamPage.not_measured()
    end
  end

  # "Founder kanban on /team" reads "a founder kanban on /team" in the sentence.
  defp ideas_item("Founder kanban" <> _rest = item), do: "a " <> String.downcase(item)
  defp ideas_item(item), do: String.downcase(item)

  defp io_label("structured"), do: "Known structure"
  defp io_label("unstructured"), do: "Free text or a messy situation"
  defp io_label("any"), do: "Anything"
  defp io_label("prose"), do: "Prose a person reads"
  defp io_label(other), do: other

  defp tool_label("Elixir" <> _rest), do: "Elixir code"
  defp tool_label("Jev" <> _rest), do: "Jev"
  defp tool_label("LLM" <> _rest), do: "An LLM (Grok)"
  defp tool_label(other), do: other

  defp call_kind("Elixir" <> _rest), do: "elixir"
  defp call_kind("Jev" <> _rest), do: "jev"
  defp call_kind("LLM" <> _rest), do: "llm"
  defp call_kind(_other), do: "neutral"

  @doc false
  @spec node_kind(String.t()) :: String.t()
  def node_kind(node) do
    cond do
      node =~ "Jev" -> "jev"
      node =~ ~r/LLM|Grok/ -> "llm"
      node =~ ~r/Elixir|LiveView/ -> "elixir"
      true -> "neutral"
    end
  end

  defp node_icon_name(node) do
    cond do
      node =~ "Player" and not (node =~ "Prose") -> "hero-user"
      node =~ "LiveView" -> "hero-bolt"
      node =~ "Jev" -> "hero-magnifying-glass"
      node =~ "Elixir" -> "hero-cog-6-tooth"
      node =~ ~r/LLM|Grok/ -> :quill
      true -> "hero-document-text"
    end
  end

  defp node_note(node, d) do
    case node_kind(node) do
      "jev" ->
        "~#{ms(get(d, ["intent_shadow", "p50_ms"]))}, #{usd(get(d, ["intent_shadow", "cost_per_turn_usd"]))} a turn"

      "llm" ->
        "writes the story, never the facts"

      "elixir" ->
        if node =~ "Elixir", do: "decides what happened, and saves it first"

      _other ->
        nil
    end
  end

  defp stack(d, keys) do
    case keys |> Enum.map(&get(d, ["infrastructure", "stack", &1])) |> Enum.reject(&is_nil/1) do
      [] -> nil
      values -> Enum.join(values, " · ")
    end
  end

  # "4.3/5 · confident 54%", from the post-rework series (Paul), the example the brief uses.
  defp score_example(d) do
    series = get(d, ["playtest_series", "series"]) || []

    with %{} = s <- Enum.find(series, &(&1["id"] == "post-rework-2026-10-08")),
         value when is_number(value) <- get(s, ["weighted", "paul"]),
         unsure when is_number(unsure) <- get(s, ["unsure_pct", "paul"]) do
      "#{score(value)} · confident #{pct(100 - unsure)}"
    else
      _missing -> get(d, ["jev_headline", "display"]) || TeamPage.not_measured()
    end
  end

  @doc false
  @spec split_highlight(String.t()) :: {String.t(), String.t(), String.t()} | String.t()
  def split_highlight(text) do
    case String.split(text, " -> ", parts: 2) do
      [before, after_arrow] ->
        case Regex.run(~r/\A(\S+)(.*)\z/s, after_arrow) do
          [_, value, rest] -> {before, value, rest}
          nil -> text
        end

      [_one] ->
        text
    end
  end

  defp within_text(within, reads) when is_integer(within) and within == reads,
    do: "all #{number(within)}"

  defp within_text(within, reads) when is_integer(within) and is_integer(reads),
    do: "#{number(within)} of #{number(reads)}"

  defp within_text(_within, _reads), do: TeamPage.not_measured()

  defp seconds(ms) when is_number(ms), do: "#{number(ms / 1000)} s"
  defp seconds(_ms), do: TeamPage.not_measured()

  defp agreement(s) do
    order = ["action", "class", "target", "skill", "later"]
    values = s["agreement_with_today_pct"] || %{}
    for key <- order, Map.has_key?(values, key), do: {key, values[key]}
  end

  defp holdout_text(nil), do: TeamPage.not_measured()
  defp holdout_text(%{"action_accuracy_pct" => v}), do: "action right #{pct(v)}"
  defp holdout_text(_other), do: "see the eval report"

  defp eval_parts(e) do
    for {key, value} <- e["categories"] || %{} do
      kind =
        cond do
          key == "real_turn" -> "real"
          String.starts_with?(key, "attack_") -> "attack"
          true -> "tricky"
        end

      %{
        label: Map.get(@category_labels, key, key),
        value: value,
        kind: kind,
        order: {kind_order(kind), -value}
      }
    end
    |> Enum.sort_by(& &1.order)
  end

  defp kind_order("real"), do: 0
  defp kind_order("attack"), do: 1
  defp kind_order(_tricky), do: 2

  defp attack_count(%{"turns" => turns}) when is_integer(turns),
    do: "#{number(turns)} hostile turns"

  defp attack_count(run), do: "#{number(length(run["attacks"] || []))} attacks"

  defp range(results, key, unit),
    do:
      TeamPage.range(
        get(results, ["timings", key, "min"]),
        get(results, ["timings", key, "max"]),
        unit
      )

  defp per_run(d) do
    values =
      (get(d, ["ai_spend", "cost_per_run_usd"]) || %{})
      |> Map.values()
      |> Enum.filter(&is_number/1)

    case values do
      [] ->
        TeamPage.not_measured()

      _some ->
        "$#{number(Enum.min(values) * 1.0, decimals: 2)}–#{number(Enum.max(values) * 1.0, decimals: 2)}"
    end
  end

  # Where the pace numbers came from, under the stats that show them: "live
  # from GitHub" or "as of <date>" (TeamPace.label/1).
  attr :id, :string, required: true
  attr :pace, :map, required: true
  attr :class, :string, default: nil

  defp pace_source(assigns) do
    ~H"""
    <p id={@id} class={["text-xs text-[var(--paper-muted)]", @class]} data-source={@pace.source}>
      Pull request and commit numbers: {TeamPace.label(@pace)}.
    </p>
    """
  end

  # PRs per day since 2026-10-07; earlier days become one chip ("+14 PRs
  # in July").
  defp split_prs_since_inception(pace) do
    days = pace.prs_by_day
    {current, _n} = TeamLiveNumbers.since_inception(days)
    {current, earlier_chip(days -- current)}
  end

  defp earlier_count(all_days, kept) do
    (all_days -- kept) |> Enum.map(&(&1["count"] || 0)) |> Enum.sum()
  end

  attr :id, :string, required: true
  attr :what, :string, required: true, doc: "which numbers, e.g. \"Tests\""
  attr :group, :map, required: true, doc: "a `TalesForgeWeb.TeamLiveNumbers` group"

  # Where a group of numbers came from: "Tests: live from CI on main (f7f3abd)."
  # or "Tests: as of 9 Oct 2026."
  defp group_source(assigns) do
    ~H"""
    <p id={@id} class="text-xs text-[var(--paper-muted)]" data-source={@group.source}>
      {@what}: {TeamLiveNumbers.label(@group)}.
    </p>
    """
  end

  defp earlier_chip([]), do: nil

  defp earlier_chip(days) do
    total = days |> Enum.map(&(&1["created"] || 0)) |> Enum.sum()

    months =
      days
      |> Enum.map(&(&1["date"] |> Date.from_iso8601!() |> Calendar.strftime("%B")))
      |> Enum.uniq()
      |> Enum.join(" and ")

    "+#{number(total)} PRs in #{months}"
  end

  # The app a live number comes from, by name: the presentation lives on
  # production (admin split 2026-10-10), so its own database is production's.
  defp app_word do
    case TalesForge.AppRole.role() do
      :production -> "production"
      :playtest -> "playtest"
      :local -> "this local app"
    end
  end
end
