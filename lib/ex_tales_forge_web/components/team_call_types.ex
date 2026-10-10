defmodule TalesForgeWeb.TeamCallTypes do
  @moduledoc """
  "The call-type rule: one turn, three call types", the walkthrough under rule
  3 in "How we work" on the founders' presentation (`/team/presentation`,
  `TalesForgeWeb.TeamPresentationLive`).

  It follows one Tin Valley turn (talking Brenna down on the price of the
  room) through the three call types: Jev reads the player's words into a
  typed intent, Elixir applies the rules, and the GM (an LLM) writes the prose.
  Then examples per type, from what the code actually does, and the
  "one turn, three lanes" animation. Each pill has a hover card
  (`TalesForgeWeb.TeamPeek`) showing what that call type looks like: code,
  data in and out, or result in and prose out.

  Copy follows tales-forge-docs `docs/team-page/content.md` (commit 404e421; unchanged since, through d118917).
  The turn's numbers (the typed intent, the roll, the price) come from
  `call_types.walkthrough` in `data.json`, the read latency and cost from
  `intent_shadow`; a missing or `null` value reads "not measured yet".

  The animation is drawn as SVG, twice: three horizontal lanes from 1024 px,
  and the same lanes stacked for phones and tablets, so no text shrinks below
  readable and nothing scrolls sideways. The lanes use the page's call-type
  colours (`--team-jev`, `--team-elixir`, `--team-llm`, with their dark
  variants in `app.css`; `call_types.colours` names them). The server renders
  the static, numbered diagram; the `TeamLanes` hook in
  `assets/js/team_hooks.js` plays it once on scroll-in (with a Replay button)
  only when `prefers-reduced-motion` is off.
  """

  use Phoenix.Component

  import TalesForge.TeamPage, only: [get: 2, number: 1, ms: 1, usd: 1, date_label: 1]

  alias TalesForge.TeamPage
  alias TalesForgeWeb.TeamPeek

  @anchor "the-call-type-rule-one-turn-three-call-types"
  @lanes ~w(jev elixir llm)
  @lane_names %{"jev" => "Jev", "elixir" => "Elixir", "llm" => "GM (LLM)"}
  @stat_names %{
    "STR" => "Strength",
    "DEX" => "Dexterity",
    "CON" => "Constitution",
    "INT" => "Intelligence",
    "WIS" => "Wisdom",
    "CHA" => "Charisma"
  }
  @player_line "I lean on the bar and try to talk Brenna down on the price of the room."
  @prose "Brenna laughs, a big warm sound, and flicks her cloth over her shoulder. " <>
           "“Lean on my bar like that and you'll wear a groove in it. Fine, fine. " <>
           "You've got an honest face, for a traveller.” She slides a heavy iron key across the oak."

  @doc ~S"""
  The id of the walkthrough, the anchor rule 3 links to (the heading's slug in
  `content.md`).

      iex> TalesForgeWeb.TeamCallTypes.anchor()
      "the-call-type-rule-one-turn-three-call-types"
  """
  @spec anchor() :: String.t()
  def anchor, do: @anchor

  @doc ~S"""
  The three lanes of the animation, top to bottom.

      iex> TalesForgeWeb.TeamCallTypes.lanes()
      ["jev", "elixir", "llm"]
  """
  @spec lanes() :: [String.t()]
  def lanes, do: @lanes

  @doc ~S"""
  Greedy word wrap into lines of at most `width` characters (a longer word
  gets a line of its own). For SVG text, which doesn't wrap by itself.

      iex> TalesForgeWeb.TeamCallTypes.wrap("one two three four", 9)
      ["one two", "three", "four"]
      iex> TalesForgeWeb.TeamCallTypes.wrap(nil, 9)
      []
  """
  @spec wrap(term(), pos_integer()) :: [String.t()]
  def wrap(text, width) when is_binary(text) do
    text
    |> String.split()
    |> Enum.reduce([], fn
      word, [] ->
        [word]

      word, [line | rest] ->
        if String.length(line) + 1 + String.length(word) <= width,
          do: [line <> " " <> word | rest],
          else: [word, line | rest]
    end)
    |> Enum.reverse()
  end

  def wrap(_text, _width), do: []

  @doc ~S"""
  Milliseconds as "about N s", rounded down to a hundredth of a second (a
  median of 255 ms reads "about 0.25 s", as in the copy).

      iex> TalesForgeWeb.TeamCallTypes.about_seconds(255)
      "about 0.25 s"
      iex> TalesForgeWeb.TeamCallTypes.about_seconds(410)
      "about 0.41 s"
      iex> TalesForgeWeb.TeamCallTypes.about_seconds(nil)
      "not measured yet"
  """
  @spec about_seconds(term()) :: String.t()
  def about_seconds(ms) when is_number(ms) and ms >= 0,
    do: "about #{hundredths(ms)} s"

  def about_seconds(_ms), do: TeamPage.not_measured()

  @doc ~S"""
  Jev's typed intent as the one-line card of the animation, from the Jev
  step's `detail`: `speak · Brenna · persuasion · now · 0.92 · safe`. A
  missing field reads "not measured yet".

      iex> TalesForgeWeb.TeamCallTypes.typed_card(%{"action" => "speak",
      ...>   "target" => "Brenna (innkeep)", "skill" => "persuasion", "when" => "this turn",
      ...>   "confidence" => 0.92, "safety" => "benign"})
      "speak · Brenna · persuasion · now · 0.92 · safe"
  """
  @spec typed_card(map()) :: String.t()
  def typed_card(detail) when is_map(detail) do
    Enum.map_join(typed_fields(detail), " · ", & &1)
  end

  defp typed_fields(detail) do
    [
      text(detail["action"]),
      short_name(detail["target"]),
      text(detail["skill"]),
      when_short(detail["when"]),
      number(detail["confidence"]),
      safety_short(detail["safety"])
    ]
  end

  @doc ~S"""
  A name without its bracketed note ("Brenna (innkeep)" -> "Brenna").

      iex> TalesForgeWeb.TeamCallTypes.short_name("Brenna (innkeep)")
      "Brenna"
      iex> TalesForgeWeb.TeamCallTypes.short_name("3 silver (price list)")
      "3 silver"
  """
  @spec short_name(term()) :: String.t()
  def short_name(value) when is_binary(value),
    do: value |> String.replace(~r/\s*\([^)]*\)\s*$/, "") |> text()

  def short_name(_value), do: TeamPage.not_measured()

  # ── The walkthrough ────────────────────────────────────────────────────────

  @doc """
  The whole subsection: intro, the rule in one breath, the smell, one turn
  start to finish, how true it is today, examples per type, the closing line
  and the three-lane animation.
  """
  attr :d, :map, required: true

  @spec walkthrough(map()) :: Phoenix.LiveView.Rendered.t()
  def walkthrough(assigns) do
    assigns = assign(assigns, turn(assigns.d))

    ~H"""
    <article
      id={anchor()}
      class="team-card team-calltypes space-y-6 p-4 sm:p-6"
      aria-labelledby="calltypes-title"
    >
      <header class="max-w-3xl space-y-2">
        <h3 id="calltypes-title" class="font-serif text-xl font-bold sm:text-2xl">
          The call-type rule: one turn, three call types
        </h3>
        <p class="text-base leading-relaxed text-[var(--paper-muted)]">
          This one rule shapes the whole game engine, so it's worth a closer look. Every bit of work in a turn goes to one of three helpers,
          depending on what goes in and what has to come out. Here is one real-feeling turn in Tin Valley, followed all the way through.
        </p>
      </header>

      <ul id="calltype-pills" class="grid gap-3 lg:grid-cols-3" aria-label="The rule in one breath">
        <li
          id="pill-elixir"
          class="team-pill team-kind-elixir space-y-1 p-3 text-sm leading-relaxed"
          style={lane_style(@colours, "elixir")}
        >
          <p>
            <.kind_name kind="elixir" colours={@colours} />
            <strong class="team-kind-text">Elixir function.</strong>
          </p>
          <p>Known, structured input in, structured output out.</p>
          <p class="text-[var(--paper-muted)]">
            <em>Why: exact, free and testable. The same input gives the same answer every time, and a test can prove it.</em>
          </p>
          <TeamPeek.elixir d={@d} />
        </li>
        <li
          id="pill-jev"
          class="team-pill team-kind-jev space-y-1 p-3 text-sm leading-relaxed"
          style={lane_style(@colours, "jev")}
        >
          <p>
            <.kind_name kind="jev" colours={@colours} />
            <strong class="team-kind-text">Jev call (TypeSafe).</strong>
          </p>
          <p>Messy, unstructured input in (a player's words, a scene), structured output out.</p>
          <p class="text-[var(--paper-muted)]">
            <em>
              Why: it turns messy words into data reliably and fast, {@read_speed} a read
              (median {ms(@p50)} in the shadow test), for about {usd(@cost_per_turn)} a turn.
            </em>
          </p>
          <TeamPeek.jev d={@d} />
        </li>
        <li
          id="pill-llm"
          class="team-pill team-kind-llm space-y-1 p-3 text-sm leading-relaxed"
          style={lane_style(@colours, "llm")}
        >
          <p>
            <.kind_name kind="llm" colours={@colours} />
            <strong class="team-kind-text">LLM call (the GM on Grok).</strong>
          </p>
          <p>Prose out, for a person to read.</p>
          <p class="text-[var(--paper-muted)]">
            <em>
              Why: it's the only one of the three that writes good prose. It's also the slowest and most expensive, so we never ask it for data.
            </em>
          </p>
          <TeamPeek.llm d={@d} prose={prose()} />
        </li>
      </ul>

      <aside id="calltype-smell" class="team-callout p-4 text-sm leading-relaxed">
        <strong>The smell to remember:</strong>
        asking the LLM for structured data (numbers, flags, lists of facts) is a warning sign.
        That work belongs to Jev or Elixir. The LLM tells the story; it doesn't keep the books.
      </aside>

      <section id="calltype-turn" class="space-y-4" aria-labelledby="calltype-turn-title">
        <h4 id="calltype-turn-title" class="font-serif text-lg font-bold">
          One turn, start to finish
        </h4>
        <p class="text-sm italic leading-relaxed text-[var(--paper-muted)]">
          Scene: the Valley Inn, evening. Brenna, the warm, chatty barkeep, is behind the bar.
          The private room is listed at {@price} a night, paid up front.
        </p>
        <div>
          <p class="text-sm font-semibold">The player types:</p>
          <blockquote id="calltype-player" class="team-quote mt-1 text-sm italic">
            “{@player_text}”
          </blockquote>
        </div>

        <ol class="space-y-4">
          <li id="turn-jev" class="team-turn-step team-kind-jev space-y-2 p-3 sm:p-4">
            <p class="text-sm leading-relaxed">
              <strong>1. <span class="team-kind-text">Jev</span> reads the words into a typed intent.</strong>
              Jev never writes text. It picks from labels the game offers, and says how sure it is:
            </p>
            <table id="turn-jev-intent" class="team-intent w-full text-left text-sm">
              <thead>
                <tr>
                  <th scope="col">Field</th><th scope="col">Jev's answer</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <th scope="row">action</th><td><code>{text(@jev["action"])}</code></td>
                </tr>
                <tr>
                  <th scope="row">target</th><td>{text(@jev["target"])}</td>
                </tr>
                <tr>
                  <th scope="row">skill</th><td><code>{text(@jev["skill"])}</code></td>
                </tr>
                <tr>
                  <th scope="row">when</th><td>{when_long(@jev["when"])}</td>
                </tr>
                <tr>
                  <th scope="row">safety</th><td>
                    <code>{text(@jev["safety"])}</code>{safety_note(@jev["safety"])}
                  </td>
                </tr>
                <tr>
                  <th scope="row">confidence</th>
                  <td>{number(@jev["confidence"])}{confidence_note(@jev["confidence"])}</td>
                </tr>
              </tbody>
            </table>
            <p class="text-sm italic text-[var(--paper-muted)]">
              In plain words: “They're trying to persuade Brenna, right now, and it's an honest move.”
            </p>
          </li>

          <li id="turn-elixir" class="team-turn-step team-kind-elixir space-y-2 p-3 sm:p-4">
            <p class="text-sm leading-relaxed">
              <strong>2. <span class="team-kind-text">Elixir</span> applies the rules.</strong>
              Now the input is known and structured, so plain code takes over. No AI involved:
            </p>
            <ul class="team-bullets space-y-1.5 text-sm leading-relaxed">
              <li id="turn-roll">
                <strong>Roll:</strong> {roll_text(@elixir["roll"])}. The character's {text(
                  @jev["skill"]
                )} is {number(@elixir["skill_level"])}, plus the {stat_name(@elixir["stat"])} bonus ({text(
                  @elixir["stat"]
                )} gives {signed(@elixir["stat_bonus"])}),
                so the target is <strong>{number(@elixir["target"])}</strong>.
                The die shows <strong>{number(@elixir["die"])}</strong>: {text(@elixir["outcome"])}.
              </li>
              <li>
                <strong>Learning:</strong>
                a success earns nothing to learn from. In Tales Forge you learn from your failures,
                and only in the skill you failed. Persuasion is not a physical skill, so a failed haggle
                would improve it during the next sleep.
              </li>
              <li>
                <strong>Price:</strong>
                the room's price comes from the game's own price list, never from the GM's imagination.
                Coins only change when the player actually pays.
              </li>
              <li>
                <strong>Records it all</strong>
                in the turn: the roll, the outcome and the price facts,
                so the next turn and the playtest reports can see exactly what happened.
              </li>
            </ul>
          </li>

          <li id="turn-llm" class="team-turn-step team-kind-llm space-y-2 p-3 sm:p-4">
            <p class="text-sm leading-relaxed">
              <strong>3. <span class="team-kind-text">The GM (LLM)</span> writes the prose.</strong>
              The GM gets the typed result (“{@gm_input}”) plus a short quote of the player's own words,
              so it keeps their tone. Then it does the one thing only it can do:
            </p>
            <blockquote id="turn-prose" class="team-quote font-serif text-base italic leading-relaxed">
              {prose()}
            </blockquote>
            <p class="text-xs italic text-[var(--paper-muted)]">
              (Sample prose, written to show the style. Not copied from a real run.)
            </p>
          </li>
        </ol>

        <div id="calltype-honesty" class="space-y-1 text-xs leading-relaxed text-[var(--paper-muted)]">
          <p class="font-semibold text-[var(--paper-ink)]">How true is this today?</p>
          <p>
            <strong>Real today:</strong>
            the Elixir roll-under check with the stat bonus, and the price list.
            The learning rule: you learn only from failure, and only in the failed skill.
            Physical skills (combat, dodge, climbing, lockpicking) improve right away, at most +1 for each long rest.
            Other skills improve during sleep. From level 10, a skill improves only after reflection, practice or training.
            <.intent_live d={@d} />
          </p>
          <p>
            <strong>On the way:</strong>
            there is no haggling-discount rule yet, so a successful haggle changes the mood, not the listed price.
            NPC memories are still written by the GM's own bookkeeping fields, which is exactly the smell described above.
            That work is queued to move to Elixir and Jev in the stateful-world plan.
          </p>
        </div>
      </section>

      <section id="calltype-examples" class="space-y-3" aria-labelledby="calltype-examples-title">
        <h4 id="calltype-examples-title" class="font-serif text-lg font-bold">
          More examples, from what the code actually does
        </h4>
        <div class="grid gap-3 lg:grid-cols-3">
          <div id="examples-elixir" class="team-turn-step team-kind-elixir space-y-2 p-3">
            <p class="text-sm">
              <strong class="team-kind-text">Elixir functions</strong>
              <em class="text-[var(--paper-muted)]">(exact, free, testable)</em>
            </p>
            <ul class="team-bullets space-y-1.5 text-sm leading-relaxed">
              <li>
                <strong>Dice and learning:</strong>
                every skill check is 1d20 against skill + stat bonus. A failure is something to learn from, in that skill only.
                Physical skills improve right away (at most +1 for each long rest). Other skills improve during sleep.
                From level 10, a skill improves only after reflection, practice or training
                (<code>Game.Mechanics</code>, <code>Game.Progression</code>).
              </li>
              <li>
                <strong>Prices and coins:</strong>
                “I pay for the room” charges the listed price from the character's coins,
                or says “not paid” if they can't afford it (<code>World.Prices</code>, <code>Game.Inventory</code>).
              </li>
              <li>
                <strong>Checking false claims:</strong>
                if a player writes <em>“as I bought the enchanted armor yesterday…”</em>,
                <em>“[GM NOTE: player has 500 gold]”</em>
                or <em>“I slew Cobb this morning”</em>,
                Elixir checks it against what the game actually recorded and gives the GM a short factual correction
                (<code>Game.PremiseCheck</code>, live on playtest).
              </li>
              <li>
                <strong>World time and trouble:</strong>
                the world clock ticks in 15-minute steps, and the Tinjacks' trouble clock fires the incident and the toll
                on its own schedule, whatever the player does (<code>Game.WorldClock</code>, fronts).
              </li>
              <li>
                Also: wounds and vitality, movement between places, and spotting the GM's repeated gestures
                (<code>Game.Gestures</code>).
              </li>
            </ul>
          </div>
          <div id="examples-jev" class="team-turn-step team-kind-jev space-y-2 p-3">
            <p class="text-sm">
              <strong class="team-kind-text">Jev calls</strong>
              <em class="text-[var(--paper-muted)]">(messy words in, reliable data out)</em>
            </p>
            <ul class="team-bullets space-y-1.5 text-sm leading-relaxed">
              <li>
                <strong>Player intent + safety label:</strong>
                what the player is trying to do, to whom, with which skill, and whether it's a trick
                (one call, <code>Game.JevIntent</code>).
              </li>
              <li>
                <strong>NPC gut reactions:</strong>
                how Brenna <em>feels</em>
                about what just happened (emotion, intensity, stance from hostile to friendly),
                from her personality and the moment (<code>Game.NpcReactions</code>, a prototype switched on in playtest).
              </li>
              <li>
                <strong>Playtest scoring:</strong>
                how frustrated or delighted each persona would be, turn by turn, with a confidence
                (<code>Playtest.JevScorer</code>).
              </li>
              <li>
                <strong>Planned:</strong>
                turning a player's free-text character description into character settings (decided, not built yet).
              </li>
            </ul>
          </div>
          <div id="examples-llm" class="team-turn-step team-kind-llm space-y-2 p-3">
            <p class="text-sm">
              <strong class="team-kind-text">LLM calls</strong>
              <em class="text-[var(--paper-muted)]">(good prose, used sparingly)</em>
            </p>
            <ul class="team-bullets space-y-1.5 text-sm leading-relaxed">
              <li><strong>GM narration:</strong> what the player sees and hears each turn.</li>
              <li>
                <strong>NPC dialogue:</strong>
                Brenna's lines, in her voice, written by the GM as part of the narration.
              </li>
              <li>
                <strong>The opening scene,</strong>
                and the persona bots' own lines when they play in playtests.
              </li>
            </ul>
          </div>
        </div>
      </section>

      <p id="calltype-closing" class="font-serif text-lg leading-relaxed">
        Each helper does what it's best at: Elixir keeps the rules, Jev understands the players, and the GM tells the story.
        Anyone in the crew can follow a turn from start to finish, and spot where something should move.
      </p>

      <.lanes {assigns} />
    </article>
    """
  end

  attr :kind, :string, required: true
  attr :colours, :map, required: true

  defp kind_name(assigns) do
    ~H"""
    <span class="team-swatch align-[-0.1em]" aria-hidden="true"></span>
    <span class="sr-only">({colour_name(@colours, @kind)})</span>
    """
  end

  attr :d, :map, required: true

  defp intent_live(assigns) do
    assigns = assign(assigns, :status, get(assigns.d, ["intent_status"]))

    ~H"""
    <%= if @status && @status["production"] == "on" && @status["playtest"] == "on" do %>
      The Jev intent read is live on both playtest and production, switched on {date_label(
        @status["since"]
      )} after the shadow test.
    <% else %>
      The Jev intent read runs in <em>shadow</em>
      on playtest: it reads every turn, but the old path still decides.
    <% end %>
    """
  end

  # ── The animation: one turn, three lanes ───────────────────────────────────

  @doc false
  @spec lanes(map()) :: Phoenix.LiveView.Rendered.t()
  def lanes(assigns) do
    assigns =
      assign(assigns,
        card: typed_card(assigns.jev),
        timer: timer_chip(assigns.latency),
        prose_wide: wrap(@prose, 46),
        prose_tall: wrap(@prose, 40),
        player_wide: wrap("“#{assigns.player_text}”", 22),
        player_tall: wrap("“#{assigns.player_text}”", 40),
        card_tall:
          assigns.jev |> typed_fields() |> Enum.chunk_every(3) |> Enum.map(&Enum.join(&1, " · "))
      )

    ~H"""
    <figure
      id="team-lanes"
      class="team-lanes space-y-3"
      phx-hook="TeamLanes"
      data-lanes="static"
      aria-labelledby="team-lanes-title"
    >
      <h4 id="team-lanes-title" class="font-serif text-lg font-bold">One turn, three lanes</h4>
      <figcaption class="sr-only">
        One turn in five steps.
        1. The player's line: “{@player_text}”.
        2. Jev lane: {step_label(@steps, "jev")}, as a typed card: {@card}. {@timer}.
        3. Elixir lane: {step_label(@steps, "elixir")}. The d20 lands on {number(@elixir["die"])} against a target of {number(
          @elixir["target"]
        )}: {text(@elixir["outcome"])}. Nothing to learn from a success. Room: {text(
          @elixir["room_price"]
        )}.
        4. GM lane: {step_label(@steps, "llm")}. It gets the card, the result and a quote of the player's words, and writes the prose.
        5. The prose goes out to the player.
        Asking the LLM for data instead would be a smell.
      </figcaption>

      <svg
        id="team-lanes-wide"
        class="hidden w-full lg:block"
        viewBox="0 0 1000 450"
        role="presentation"
        aria-hidden="true"
      >
        <defs>
          <marker
            id="tl-head-wide"
            viewBox="0 0 10 10"
            refX="9"
            refY="5"
            markerWidth="7"
            markerHeight="7"
            orient="auto-start-reverse"
          >
            <path d="M0 0 L10 5 L0 10 Z" class="tl-head" />
          </marker>
        </defs>
        <%!-- Lanes, top to bottom: Jev, Elixir, GM. --%>
        <g
          :for={{lane, y, h} <- [{"jev", 16, 112}, {"elixir", 140, 130}, {"llm", 282, 156}]}
          class={"team-kind-#{lane}"}
          style={lane_style(@colours, lane)}
          data-lane={lane}
        >
          <rect x="180" y={y} width="672" height={h} rx="10" class="tl-band" />
          <text x="196" y={y + 28} class="tl-kind tl-lane-name">{lane_name(lane)}</text>
          <text
            :for={{line, i} <- Enum.with_index(wrap(step_label(@steps, lane), 16))}
            x="196"
            y={y + 48 + i * 15}
            class="tl-muted tl-small"
          >
            {line}
          </text>
        </g>

        <%!-- 1. The player's line drops in at the left. --%>
        <g data-at="1" data-move="drop">
          <path
            d="M14 24 H160 a8 8 0 0 1 8 8 V118 a8 8 0 0 1 -8 8 H60 L44 142 L46 126 H22 a8 8 0 0 1 -8 -8 V32 a8 8 0 0 1 8 -8 Z"
            class="tl-bubble"
          />
          <text x="26" y="46" class="tl-ink tl-small tl-bold">The player</text>
          <text
            :for={{line, i} <- Enum.with_index(@player_wide)}
            x="26"
            y={64 + i * 15}
            class="tl-ink tl-small tl-italic"
          >
            {line}
          </text>
          <.badge n={1} x={14} y={24} />
        </g>
        <path
          d="M172 96 H330"
          class="tl-arrow"
          marker-end="url(#tl-head-wide)"
          data-at="2"
          data-move="fade"
        />

        <%!-- 2. Jev turns it into a typed card. --%>
        <g class="team-kind-jev" style={lane_style(@colours, "jev")} data-at="2" data-move="slide">
          <rect x="340" y="66" width="380" height="44" rx="8" class="tl-card" />
          <text x="530" y="93" text-anchor="middle" class="tl-ink tl-mono">{@card}</text>
          <rect x="732" y="74" width="104" height="28" rx="14" class="tl-chip" />
          <text x="784" y="93" text-anchor="middle" class="tl-kind tl-small tl-bold">{@timer}</text>
          <.badge n={2} x={340} y={66} />
        </g>
        <path
          d="M530 112 V150"
          class="tl-arrow"
          marker-end="url(#tl-head-wide)"
          data-at="3"
          data-move="fade"
        />

        <%!-- 3. Elixir rolls the d20 and stamps the result. --%>
        <g
          class="team-kind-elixir"
          style={lane_style(@colours, "elixir")}
          data-at="3"
          data-move="drop"
        >
          <rect x="340" y="156" width="380" height="36" rx="8" class="tl-card tl-card-faint" />
          <text x="530" y="179" text-anchor="middle" class="tl-muted tl-mono tl-small">{@card}</text>
          <.die x={370} y={232} value={die_face(@elixir["die"])} />
          <text x="404" y="224" class="tl-ink tl-small">
            lands on
            <tspan class="tl-bold">{number(@elixir["die"])}</tspan>
          </text>
          <text x="404" y="242" class="tl-ink tl-small">
            target
            <tspan class="tl-bold">{number(@elixir["target"])}</tspan>
          </text>
          <g class="tl-stamp">
            <rect x="490" y="212" width="94" height="30" rx="6" />
            <text x="537" y="232" text-anchor="middle" class="tl-small tl-bold">
              ✓ {text(@elixir["outcome"])}
            </text>
          </g>
          <g class="tl-chips">
            <rect x="602" y="204" width="240" height="24" rx="12" class="tl-chip" />
            <text x="722" y="220" text-anchor="middle" class="tl-ink tl-tiny">
              nothing to learn from a success
            </text>
            <rect x="602" y="234" width="240" height="24" rx="12" class="tl-chip" />
            <text x="722" y="250" text-anchor="middle" class="tl-ink tl-tiny">
              room: {text(@elixir["room_price"])}
            </text>
          </g>
          <.badge n={3} x={340} y={156} />
        </g>
        <path
          d="M430 262 V300"
          class="tl-arrow"
          marker-end="url(#tl-head-wide)"
          data-at="4"
          data-move="fade"
        />

        <%!-- 4. The GM gets the bundle; a quill writes the prose. --%>
        <g class="team-kind-llm" style={lane_style(@colours, "llm")} data-at="4" data-move="drop">
          <rect x="340" y="306" width="180" height="72" rx="8" class="tl-card" />
          <text x="352" y="326" class="tl-ink tl-tiny tl-bold">the bundle</text>
          <text x="352" y="343" class="tl-ink tl-tiny">typed card + result</text>
          <text x="352" y="360" class="tl-ink tl-tiny">+ “the player's words”</text>
          <path d="M528 342 H548" class="tl-arrow" marker-end="url(#tl-head-wide)" />
          <rect x="556" y="294" width="288" height="134" rx="6" class="tl-parchment" />
          <text
            :for={{line, i} <- Enum.with_index(@prose_wide)}
            x="568"
            y={314 + i * 17}
            class="tl-ink tl-small tl-serif tl-line"
            style={"animation-delay: #{0.3 + i * 0.25}s"}
          >
            {line}
          </text>
          <g class="tl-quill">
            <path
              d="M846 278 C836 282 828 292 822 308 L824 310 C829 299 836 290 846 278 Z"
              class="tl-kind-fill"
            />
            <path d="M822 308 L818 314" class="tl-kind-stroke" />
          </g>
          <.badge n={4} x={340} y={306} />
        </g>

        <%!-- 5. The parchment slides out to the player. --%>
        <g data-at="5" data-move="out">
          <path d="M848 360 H878" class="tl-arrow" marker-end="url(#tl-head-wide)" />
          <rect x="886" y="334" width="40" height="52" rx="4" class="tl-parchment" />
          <path d="M893 348 H919 M893 357 H919 M893 366 H912" class="tl-rule" />
          <text x="936" y="356" class="tl-ink tl-tiny tl-bold">to the</text>
          <text x="936" y="370" class="tl-ink tl-tiny tl-bold">player</text>
          <.badge n={5} x={886} y={334} />
        </g>

        <%!-- The smell: the LLM asked for data, crossed out. --%>
        <g class="tl-smell-group">
          <rect x="896" y="36" width="58" height="24" rx="5" class="tl-data" />
          <text x="925" y="53" text-anchor="middle" class="tl-muted tl-tiny tl-bold">data</text>
          <path d="M925 318 V66" class="tl-smell" marker-end="url(#tl-head-wide)" />
          <path d="M913 128 L937 152 M937 128 L913 152" class="tl-cross" />
          <rect x="866" y="166" width="118" height="44" rx="5" class="tl-mask" />
          <text x="925" y="184" text-anchor="middle" class="tl-ink tl-tiny tl-bold">LLM → data?</text>
          <text x="925" y="201" text-anchor="middle" class="tl-ink tl-tiny">That's a smell.</text>
        </g>
      </svg>

      <svg
        id="team-lanes-tall"
        class="mx-auto block w-full max-w-sm lg:hidden"
        viewBox={"0 0 300 #{tall_height(@prose_tall)}"}
        role="presentation"
        aria-hidden="true"
      >
        <defs>
          <marker
            id="tl-head-tall"
            viewBox="0 0 10 10"
            refX="9"
            refY="5"
            markerWidth="7"
            markerHeight="7"
            orient="auto-start-reverse"
          >
            <path d="M0 0 L10 5 L0 10 Z" class="tl-head" />
          </marker>
        </defs>
        <g data-at="1" data-move="drop">
          <rect
            x="4"
            y="4"
            width="292"
            height={30 + length(@player_tall) * 16}
            rx="10"
            class="tl-bubble"
          />
          <text x="34" y="24" class="tl-ink tl-small tl-bold">The player</text>
          <text
            :for={{line, i} <- Enum.with_index(@player_tall)}
            x="16"
            y={42 + i * 16}
            class="tl-ink tl-small tl-italic"
          >
            {line}
          </text>
          <.badge n={1} x={18} y={19} />
        </g>
        <path
          d="M150 84 V100"
          class="tl-arrow"
          marker-end="url(#tl-head-tall)"
          data-at="2"
          data-move="fade"
        />

        <g class="team-kind-jev" style={lane_style(@colours, "jev")} data-lane="jev">
          <rect x="4" y="106" width="292" height="122" rx="10" class="tl-band" />
          <text x="16" y="130" class="tl-kind tl-lane-name">{lane_name("jev")}</text>
          <text x="16" y="147" class="tl-muted tl-small">{step_label(@steps, "jev")}</text>
          <g data-at="2" data-move="slide">
            <rect x="196" y="114" width="92" height="26" rx="13" class="tl-chip" />
            <text x="242" y="132" text-anchor="middle" class="tl-kind tl-small tl-bold">
              {@timer}
            </text>
            <rect x="16" y="160" width="268" height="58" rx="8" class="tl-card" />
            <text
              :for={{line, i} <- Enum.with_index(@card_tall)}
              x="150"
              y={184 + i * 20}
              text-anchor="middle"
              class="tl-ink tl-mono"
            >
              {line}
            </text>
            <.badge n={2} x={16} y={162} />
          </g>
        </g>
        <path
          d="M150 230 V246"
          class="tl-arrow"
          marker-end="url(#tl-head-tall)"
          data-at="3"
          data-move="fade"
        />

        <g class="team-kind-elixir" style={lane_style(@colours, "elixir")} data-lane="elixir">
          <rect x="4" y="252" width="292" height="150" rx="10" class="tl-band" />
          <text x="16" y="276" class="tl-kind tl-lane-name">{lane_name("elixir")}</text>
          <text x="16" y="293" class="tl-muted tl-small">{step_label(@steps, "elixir")}</text>
          <g data-at="3" data-move="drop">
            <.die x={58} y={326} value={die_face(@elixir["die"])} />
            <text x="86" y="320" class="tl-ink tl-small">
              lands on
              <tspan class="tl-bold">{number(@elixir["die"])}</tspan>
            </text>
            <text x="86" y="338" class="tl-ink tl-small">
              target
              <tspan class="tl-bold">{number(@elixir["target"])}</tspan>
            </text>
            <g class="tl-stamp">
              <rect x="176" y="310" width="100" height="30" rx="6" />
              <text x="226" y="330" text-anchor="middle" class="tl-small tl-bold">
                ✓ {text(@elixir["outcome"])}
              </text>
            </g>
            <g class="tl-chips">
              <rect x="16" y="352" width="268" height="20" rx="10" class="tl-chip" />
              <text x="150" y="366" text-anchor="middle" class="tl-ink tl-tiny">
                nothing to learn from a success
              </text>
              <rect x="16" y="376" width="268" height="20" rx="10" class="tl-chip" />
              <text x="150" y="390" text-anchor="middle" class="tl-ink tl-tiny">
                room: {text(@elixir["room_price"])}
              </text>
            </g>
            <.badge n={3} x={30} y={308} />
          </g>
        </g>
        <path
          d="M150 404 V420"
          class="tl-arrow"
          marker-end="url(#tl-head-tall)"
          data-at="4"
          data-move="fade"
        />

        <g class="team-kind-llm" style={lane_style(@colours, "llm")} data-lane="llm">
          <rect
            x="4"
            y="426"
            width="292"
            height={96 + length(@prose_tall) * 16}
            rx="10"
            class="tl-band"
          />
          <text x="16" y="450" class="tl-kind tl-lane-name">{lane_name("llm")}</text>
          <text x="16" y="467" class="tl-muted tl-small">{step_label(@steps, "llm")}</text>
          <g data-at="4" data-move="drop">
            <rect x="16" y="478" width="268" height="24" rx="8" class="tl-card" />
            <text x="150" y="494" text-anchor="middle" class="tl-ink tl-tiny">
              typed card + result + “the player's words”
            </text>
            <rect
              x="16"
              y="510"
              width="268"
              height={length(@prose_tall) * 16 + 18}
              rx="6"
              class="tl-parchment"
            />
            <text
              :for={{line, i} <- Enum.with_index(@prose_tall)}
              x="26"
              y={530 + i * 16}
              class="tl-ink tl-small tl-serif tl-line"
              style={"animation-delay: #{0.3 + i * 0.25}s"}
            >
              {line}
            </text>
            <g class="tl-quill">
              <path
                d="M290 506 C282 510 276 518 272 530 L274 532 C278 523 283 516 290 506 Z"
                class="tl-kind-fill"
              />
            </g>
            <.badge n={4} x={16} y={478} />
          </g>
        </g>

        <g class="tl-smell-group">
          <path
            d={"M24 #{tall_smell_y(@prose_tall) + 28} V#{tall_smell_y(@prose_tall)}"}
            class="tl-smell"
            marker-end="url(#tl-head-tall)"
          />
          <path
            d={"M16 #{tall_smell_y(@prose_tall) + 6} L32 #{tall_smell_y(@prose_tall) + 22} M32 #{tall_smell_y(@prose_tall) + 6} L16 #{tall_smell_y(@prose_tall) + 22}"}
            class="tl-cross"
          />
          <text x="44" y={tall_smell_y(@prose_tall) + 18} class="tl-ink tl-tiny">
            <tspan class="tl-bold">LLM → data?</tspan>
            That's a smell.
          </text>
        </g>

        <g data-at="5" data-move="out">
          <path
            d={"M150 #{tall_out_y(@prose_tall)} V#{tall_out_y(@prose_tall) + 16}"}
            class="tl-arrow"
            marker-end="url(#tl-head-tall)"
          />
          <rect
            x="96"
            y={tall_out_y(@prose_tall) + 22}
            width="108"
            height="28"
            rx="6"
            class="tl-parchment"
          />
          <text
            x="150"
            y={tall_out_y(@prose_tall) + 41}
            text-anchor="middle"
            class="tl-ink tl-small tl-bold"
          >
            to the player
          </text>
          <.badge n={5} x={96} y={tall_out_y(@prose_tall) + 22} />
        </g>
      </svg>

      <ol class="sr-only">
        <li :for={lane <- lanes()}>{lane_name(lane)}: {step_label(@steps, lane)}</li>
      </ol>

      <button
        type="button"
        id="replay-lanes"
        aria-label="Replay the animation of the three lanes"
        class="team-replay-btn min-h-11 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--paper-accent)] inline-flex items-center gap-1.5 rounded-full border border-[var(--paper-rule)] px-3 py-1 text-sm hover:bg-[var(--paper-bg)]"
        data-lanes-replay
      >
        <span aria-hidden="true">↻</span> Replay
      </button>
    </figure>
    """
  end

  attr :n, :integer, required: true
  attr :x, :integer, required: true
  attr :y, :integer, required: true

  defp badge(assigns) do
    ~H"""
    <g class="tl-badge">
      <circle cx={@x} cy={@y} r="10" />
      <text x={@x} y={@y + 4} text-anchor="middle">{@n}</text>
    </g>
    """
  end

  attr :x, :integer, required: true
  attr :y, :integer, required: true
  attr :value, :string, required: true

  defp die(assigns) do
    ~H"""
    <g transform={"translate(#{@x} #{@y})"}>
      <g class="tl-die">
        <path
          d="M0 -20 L17 -10 V10 L0 20 L-17 10 V-10 Z"
          fill="#f2b544"
          stroke="#8a5a1b"
          stroke-width="1.5"
        />
        <path
          d="M0 -20 V-12 M17 -10 L11 8 M-17 -10 L-11 8 M0 -12 L11 8 L-11 8 Z"
          stroke="#8a5a1b"
          stroke-width="1"
          fill="none"
        />
        <text x="0" y="5" text-anchor="middle" font-size="11" font-weight="700" fill="#5c3a0e">
          {@value}
        </text>
      </g>
    </g>
    """
  end

  # ── Data ───────────────────────────────────────────────────────────────────

  defp turn(d) do
    steps = get(d, ["call_types", "walkthrough", "steps"]) || []
    jev = detail(steps, "jev")
    elixir = detail(steps, "elixir")
    latency = latency(d, steps)

    %{
      steps: steps,
      colours: get(d, ["call_types", "colours"]) || %{},
      jev: jev,
      elixir: elixir,
      latency: latency,
      p50: get(d, ["intent_shadow", "p50_ms"]),
      read_speed: about_seconds(get(d, ["intent_shadow", "p50_ms"])),
      cost_per_turn: get(d, ["intent_shadow", "cost_per_turn_usd"]),
      price: short_name(elixir["room_price"]),
      player_text: get(d, ["call_types", "walkthrough", "player_text"]) || @player_line,
      gm_input:
        Enum.join(
          [
            text(jev["skill"]),
            text(elixir["outcome"]),
            short_name(jev["target"]),
            "room listed at #{short_name(elixir["room_price"])}"
          ],
          ", "
        )
    }
  end

  defp step(steps, lane), do: Enum.find(steps, %{}, &(is_map(&1) and &1["lane"] == lane))

  defp detail(steps, lane) do
    case step(steps, lane)["detail"] do
      %{} = detail -> detail
      _other -> %{}
    end
  end

  # The Jev step names the number it quotes (`latency_ref`, a dotted path).
  defp latency(d, steps) do
    case step(steps, "jev")["latency_ref"] do
      ref when is_binary(ref) -> get(d, String.split(ref, "."))
      _none -> get(d, ["intent_shadow", "p50_ms"])
    end
  end

  defp step_label(steps, lane) do
    case step(steps, lane)["label"] do
      label when is_binary(label) and label != "" -> label
      _none -> lane_name(lane)
    end
  end

  defp lane_name(lane), do: Map.get(@lane_names, lane, lane)

  # The lane's colour from `call_types.colours` (its CSS variable); the
  # `team-kind-*` class gives the same colour when the data has none.
  defp lane_style(colours, lane) do
    case get(colours, [lane, "css_var"]) do
      "--team-" <> _ = var -> "--team-kind: var(#{var})"
      _none -> nil
    end
  end

  defp colour_name(colours, kind), do: get(colours, [kind, "name"]) || lane_name(kind)

  defp timer_chip(ms) when is_number(ms) and ms >= 0, do: "~#{hundredths(ms)} s"
  defp timer_chip(_ms), do: TeamPage.not_measured()

  # Milliseconds as seconds, rounded down to the hundredth in integer maths
  # (Float.floor(0.41, 2) would give 0.4).
  defp hundredths(ms), do: number((ms |> trunc() |> div(10)) / 100)

  defp text(value) when is_binary(value) and value != "", do: value
  defp text(value) when is_number(value), do: number(value)
  defp text(_value), do: TeamPage.not_measured()

  defp when_short("this turn"), do: "now"
  defp when_short(value), do: text(value)

  defp when_long("this turn"), do: "this turn (nothing deferred)"
  defp when_long(value), do: text(value)

  defp safety_short("benign"), do: "safe"
  defp safety_short(value), do: text(value)

  defp safety_note("benign"), do: " (no trick, no injection)"
  defp safety_note(_value), do: ""

  defp confidence_note(c) when is_number(c),
    do: ", so act on it without asking the player to clarify"

  defp confidence_note(_c), do: ""

  defp roll_text(roll) when is_binary(roll),
    do: String.replace(roll, " roll-under", ", roll-under")

  defp roll_text(roll), do: text(roll)

  defp stat_name(stat) when is_binary(stat) do
    stat |> String.split() |> List.first() |> then(&Map.get(@stat_names, &1, &1))
  end

  defp stat_name(_stat), do: "stat"

  defp signed(n) when is_number(n) and n >= 0, do: "+" <> number(n)
  defp signed(n), do: number(n)

  defp prose, do: @prose

  # The face of the drawn d20: the number, or "?" when the roll isn't in the data.
  defp die_face(die) when is_integer(die), do: Integer.to_string(die)
  defp die_face(_die), do: "?"

  # The tall SVG grows with the prose; these place what comes after it.
  defp tall_smell_y(lines), do: 426 + 96 + length(lines) * 16 + 8
  defp tall_out_y(lines), do: tall_smell_y(lines) + 34
  defp tall_height(lines), do: tall_out_y(lines) + 56
end
