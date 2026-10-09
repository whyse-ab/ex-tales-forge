defmodule TalesForgeWeb.TeamPeek do
  @moduledoc """
  Hover cards ("peeks") on the three call-type pills of the call-type
  walkthrough (`TalesForgeWeb.TeamCallTypes`) on `/team/presentation`: what
  each call type actually looks like, for readers who don't write code.

  - **Elixir:** a short, simplified version of the real roll-under check
    (`TalesForge.Game.Mechanics.perform_and_apply/4`): effective level, a d20,
    success, partial success or failure.
  - **Jev:** data in (the player's words plus a little context: where they
    are, who is nearby) and the typed intent out, as JSON.
  - **GM (LLM):** the typed turn result in, prose out.

  The turn's values (the intent, the roll, the price, the player's words) come
  from `call_types.walkthrough` in `data.json`, like the rest of the
  walkthrough, so the cards always agree with the page around them.

  Each card opens on hover (mouse), on keyboard focus of its button, and on a
  tap or click (which keeps it open); Esc closes it and returns focus to the
  button, a tap or click outside closes it. The button carries
  `aria-expanded`, `aria-controls` (the card) and `aria-describedby` (the
  card's one-line summary). The behaviour is in the `TeamPage` root hook
  (`assets/js/team_hooks.js`, "Peeks"); without JavaScript the cards stay
  closed and the pills read as before. Styles are Tailwind classes here (no
  shared CSS): the fade and slide only run with motion allowed
  (`motion-safe:`), and a card is never wider than its pill on phones (code lines are
  short, and wrap rather than scroll if they must).

  Code is highlighted on the server (`highlight/1`), with plain spans: no
  highlighting library.
  """

  use Phoenix.Component

  import TalesForge.TeamPage, only: [get: 2]

  @elixir_code """
  @spec roll(map(), skill()) :: outcome()
  def roll(char, skill) do
    # skill level + (stat - 10) div 2
    level = effective_level(char, skill)
    d20 = :rand.uniform(20)

    cond do
      d20 <= level -> :success
      d20 <= level + 3 -> :partial_success
      true -> :failure
    end
  end
  """

  # One token class per kind. Full literal strings, so Tailwind finds them.
  @token_classes %{
    comment: "italic text-[var(--paper-muted)]",
    key: "text-[var(--team-jev)]",
    string: "text-[var(--team-llm)]",
    attr: "font-semibold text-[var(--team-elixir)]",
    keyword: "font-semibold text-[var(--team-elixir)]",
    atom: "text-[var(--team-jev)]",
    number: "text-[var(--team-llm)]",
    call: "text-[var(--paper-ink)] underline decoration-dotted underline-offset-2"
  }

  @token ~r/(#[^\n]*)|("[^"\n]*"(?=\s*:))|("[^"\n]*")|(@\w+)|(:\w+)|\b(def|do|end|cond|true|false|nil)\b|(\b\d+(?:\.\d+)?\b)|(\b[a-z_]\w*[?!]?(?=\())/
  @kinds [:comment, :key, :string, :attr, :atom, :keyword, :number, :call]

  @doc """
  The Elixir snippet on the Elixir card: a simplified version of the real
  roll-under check, 8 to 12 lines.

      iex> lines = String.split(TalesForgeWeb.TeamPeek.elixir_code(), "\\n", trim: true)
      iex> length(lines) in 8..12
      true
  """
  @spec elixir_code() :: String.t()
  def elixir_code, do: @elixir_code

  @doc """
  Splits code (Elixir or JSON) into `{kind, text}` tokens for highlighting;
  `kind` is nil for plain text. Joining the texts gives the code back.

      iex> TalesForgeWeb.TeamPeek.highlight("d20 <= level -> :success # yes")
      [{nil, "d20 <= level -> "}, {:atom, ":success"}, {nil, " "}, {:comment, "# yes"}]
      iex> TalesForgeWeb.TeamPeek.highlight(~s({"skill": "persuasion", "confidence": 0.92}))
      [{nil, "{"}, {:key, ~s("skill")}, {nil, ": "}, {:string, ~s("persuasion")}, {nil, ", "},
       {:key, ~s("confidence")}, {nil, ": "}, {:number, "0.92"}, {nil, "}"}]
  """
  @spec highlight(String.t()) :: [{atom() | nil, String.t()}]
  def highlight(code) when is_binary(code) do
    {tokens, rest_at} =
      @token
      |> Regex.scan(code, return: :index)
      |> Enum.reduce({[], 0}, fn [{at, len} | groups], {acc, pos} ->
        acc = if at > pos, do: [{nil, binary_part(code, pos, at - pos)} | acc], else: acc
        {[{kind(groups), binary_part(code, at, len)} | acc], at + len}
      end)

    tail = binary_part(code, rest_at, byte_size(code) - rest_at)
    tokens = if tail == "", do: tokens, else: [{nil, tail} | tokens]
    Enum.reverse(tokens)
  end

  defp kind(groups) do
    groups
    |> Enum.zip(@kinds)
    |> Enum.find_value(fn {{at, _len}, kind} -> if at >= 0, do: kind end)
  end

  @doc """
  The tokens of `highlight/1` as safe HTML: plain text escaped, each token in
  a `<span>` with its colour class.

      iex> TalesForgeWeb.TeamPeek.highlight_html("<x> :ok") |> Phoenix.HTML.safe_to_string()
      ~s{&lt;x&gt; <span class="text-[var(--team-jev)]">:ok</span>}
  """
  @spec highlight_html(String.t()) :: Phoenix.HTML.safe()
  def highlight_html(code) do
    iodata =
      for {kind, text} <- code |> highlight() |> glue_whitespace() do
        {:safe, escaped} = Phoenix.HTML.html_escape(text)

        case kind do
          nil -> escaped
          kind -> [~s(<span class="), @token_classes[kind], ~s(">), escaped, "</span>"]
        end
      end

    {:safe, iodata}
  end

  # Whitespace-only text between two spans goes into the span before it, so
  # no tool that drops whitespace-only text nodes can run the code together.
  defp glue_whitespace(tokens) do
    tokens
    |> Enum.reduce([], fn
      {nil, text} = token, [{kind, prev} | rest] = acc when kind != nil ->
        if String.trim(text) == "", do: [{kind, prev <> text} | rest], else: [token | acc]

      token, acc ->
        [token | acc]
    end)
    |> Enum.reverse()
  end

  @doc """
  JSON of `pairs` (`{key, value}` in order), one key a line, two-space
  indent, as the cards show it.

      iex> TalesForgeWeb.TeamPeek.json([{"action", "speak"}, {"confidence", 0.92}])
      ~s({\\n  "action": "speak",\\n  "confidence": 0.92\\n})
  """
  @spec json([{String.t(), term()}]) :: String.t()
  def json(pairs) do
    lines = Enum.map(pairs, fn {key, value} -> ~s(  "#{key}": #{Jason.encode!(value)}) end)
    "{\n" <> Enum.join(lines, ",\n") <> "\n}"
  end

  @doc """
  The typed intent Jev returns for the walkthrough's turn, from the Jev step's
  `detail` in `data.json`: target as the NPC's id, timing "now" for this turn.

      iex> TalesForgeWeb.TeamPeek.jev_output(%{"action" => "speak", "target" => "Brenna (innkeep)",
      ...>   "skill" => "persuasion", "when" => "this turn", "confidence" => 0.92, "safety" => "benign"})
      [{"action", "speak"}, {"target", "brenna"}, {"skill", "persuasion"}, {"timing", "now"},
       {"confidence", 0.92}, {"safety", "benign"}]
  """
  @spec jev_output(map()) :: [{String.t(), term()}]
  def jev_output(jev) do
    [
      {"action", jev["action"]},
      {"target", target_id(jev["target"])},
      {"skill", jev["skill"]},
      {"timing", timing(jev["when"])},
      {"confidence", jev["confidence"]},
      {"safety", jev["safety"]}
    ]
  end

  @doc """
  The typed turn result the GM gets for the walkthrough's turn: the intent,
  Elixir's roll and outcome, the price, and a short quote of the player.

      iex> TalesForgeWeb.TeamPeek.gm_input(%{"action" => "speak", "target" => "Brenna (innkeep)",
      ...>   "skill" => "persuasion"}, %{"die" => 6, "target" => 7, "outcome" => "success",
      ...>   "room_price" => "3 silver (price list)"})
      [{"action", "speak"}, {"target", "brenna"}, {"skill", "persuasion"}, {"roll", 6},
       {"needed", 7}, {"outcome", "success"}, {"room_price", "3 silver"},
       {"player_said", "talk Brenna down"}]
  """
  @spec gm_input(map(), map()) :: [{String.t(), term()}]
  def gm_input(jev, elixir) do
    [
      {"action", jev["action"]},
      {"target", target_id(jev["target"])},
      {"skill", jev["skill"]},
      {"roll", elixir["die"]},
      {"needed", elixir["target"]},
      {"outcome", elixir["outcome"]},
      {"room_price", short(elixir["room_price"])},
      {"player_said", "talk Brenna down"}
    ]
  end

  defp target_id(value) when is_binary(value),
    do: value |> String.split([" ", "("], trim: true) |> List.first("") |> String.downcase()

  defp target_id(_value), do: nil

  defp timing("this turn"), do: "now"
  defp timing(value), do: value

  defp short(value) when is_binary(value), do: value |> String.split(" (") |> hd()
  defp short(value), do: value

  # ── The card ──────────────────────────────────────────────────────────────

  attr :kind, :string, required: true, doc: "elixir, jev or llm"
  attr :label, :string, required: true, doc: "the button's text"
  attr :title, :string, required: true
  attr :gist, :string, required: true, doc: "one line, plain words; the button's description"
  attr :align, :atom, default: :left, values: [:left, :right]
  slot :inner_block, required: true

  @doc """
  One peek: a button and its card. Closed as rendered; the `TeamPage` hook
  opens and closes it (`data-open` on the wrapper, `aria-expanded` on the
  button).
  """
  @spec peek(map()) :: Phoenix.LiveView.Rendered.t()
  def peek(assigns) do
    ~H"""
    <div id={"peek-#{@kind}"} class="group/peek relative" data-peek>
      <button
        type="button"
        id={"peek-#{@kind}-button"}
        class="inline-flex min-h-11 items-center gap-1.5 rounded-full border border-[var(--team-kind)] px-3 py-1 text-sm font-semibold text-[var(--team-kind)] hover:bg-[color-mix(in_srgb,var(--team-kind)_10%,transparent)] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-[var(--team-kind)]"
        aria-expanded="false"
        aria-controls={"peek-#{@kind}-card"}
        aria-describedby={"peek-#{@kind}-gist"}
        data-peek-trigger
      >
        {@label}
        <span
          aria-hidden="true"
          class="inline-block text-xs group-data-[open]/peek:rotate-180 motion-safe:transition-transform"
        >
          ▾
        </span>
      </button>
      <div
        id={"peek-#{@kind}-card"}
        role="group"
        aria-labelledby={"peek-#{@kind}-title"}
        class={[
          "invisible absolute inset-x-0 max-sm:-inset-x-3 top-full z-30 mt-2 max-w-[calc(100vw-2rem)] space-y-2 rounded-lg border border-[var(--paper-rule)] border-t-4 border-t-[var(--team-kind)] bg-[var(--paper-panel)] p-3 text-sm leading-relaxed text-[var(--paper-ink)] opacity-0 shadow-lg",
          "group-data-[open]/peek:visible group-data-[open]/peek:opacity-100",
          "motion-safe:translate-y-1 motion-safe:transition-[opacity,translate] motion-safe:duration-150 motion-safe:group-data-[open]/peek:translate-y-0",
          "lg:w-[26rem]",
          @align == :right && "lg:left-auto lg:right-0",
          @align == :left && "lg:right-auto"
        ]}
        data-peek-card
      >
        <p id={"peek-#{@kind}-title"} class="font-semibold">{@title}</p>
        <p id={"peek-#{@kind}-gist"} class="text-[var(--paper-muted)]">{@gist}</p>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :code, :string, required: true
  attr :label, :string, required: true
  attr :id, :string, required: true

  defp code_block(assigns) do
    ~H"""
    <pre
      id={@id}
      class="whitespace-pre-wrap break-words rounded-md border border-[var(--paper-rule)] bg-[var(--paper-bg)] px-2 py-2 font-mono text-[11px] leading-snug sm:text-xs"
      aria-label={@label}
      tabindex="0"
    ><code class="rounded-none! bg-transparent! p-0! text-[1em]! [overflow-wrap:normal]!">{highlight_html(@code)}</code></pre>
    """
  end

  # ── The three cards ───────────────────────────────────────────────────────

  attr :d, :map, required: true

  @doc "The Elixir card: the roll-under check, simplified."
  @spec elixir(map()) :: Phoenix.LiveView.Rendered.t()
  def elixir(assigns) do
    assigns = assign(assigns, :code, @elixir_code)

    ~H"""
    <.peek
      kind="elixir"
      label="See the code"
      title="What an Elixir function looks like"
      gist="Roll a 20-sided die against your skill: at or under it you succeed, up to 3 over is a partial success, more than that fails."
    >
      <.code_block id="peek-elixir-code" code={@code} label="Elixir code: the skill check" />
      <p class="text-xs text-[var(--paper-muted)]">
        Simplified from the game's real check (<code>Game.Mechanics</code>). The real one also handles a natural 1 and 20 and
        notes what the character learns. Same input, same answer, every time, so a test can prove it.
      </p>
    </.peek>
    """
  end

  attr :d, :map, required: true

  @doc "The Jev card: the player's words and a little context in, the typed intent out."
  @spec jev(map()) :: Phoenix.LiveView.Rendered.t()
  def jev(assigns) do
    jev = walkthrough_detail(assigns.d, "jev")

    assigns =
      assign(assigns,
        words: get(assigns.d, ["call_types", "walkthrough", "player_text"]),
        output: json(jev_output(jev))
      )

    ~H"""
    <.peek
      kind="jev"
      label="See the data"
      title="What goes into Jev, and what comes out"
      gist="In: the player's own words and where they are. Out: a small, typed answer the game can act on."
    >
      <dl class="space-y-1 text-xs">
        <div>
          <dt class="inline font-semibold">The player's words:</dt>
          <dd id="peek-jev-words" class="inline italic">“{@words || "not measured yet"}”</dd>
        </div>
        <div>
          <dt class="inline font-semibold">Where:</dt>
          <dd class="inline">the Valley Inn (<code>valley_inn</code>), evening</dd>
        </div>
        <div>
          <dt class="inline font-semibold">Who's nearby:</dt>
          <dd class="inline">Brenna, the innkeep (<code>brenna</code>)</dd>
        </div>
      </dl>
      <p class="text-xs font-semibold">Jev answers with typed data, never text:</p>
      <.code_block id="peek-jev-output" code={@output} label="Jev's answer as JSON" />
    </.peek>
    """
  end

  attr :d, :map, required: true
  attr :prose, :string, required: true, doc: "the walkthrough's GM prose"

  @doc "The GM (LLM) card: the typed turn result in, prose out."
  @spec llm(map()) :: Phoenix.LiveView.Rendered.t()
  def llm(assigns) do
    input =
      gm_input(walkthrough_detail(assigns.d, "jev"), walkthrough_detail(assigns.d, "elixir"))

    assigns = assign(assigns, :input, json(input))

    ~H"""
    <.peek
      kind="llm"
      label="See in and out"
      title="What the GM gets, and what it writes"
      gist="In: the turn already decided, as typed data. Out: a few lines of story for the player."
      align={:right}
    >
      <p class="text-xs font-semibold">In: the result, already decided by Jev and Elixir</p>
      <.code_block id="peek-llm-input" code={@input} label="The turn result the GM gets, as JSON" />
      <p class="text-xs font-semibold">Out: prose, for a person to read</p>
      <blockquote
        id="peek-llm-prose"
        class="border-l-2 border-[var(--team-kind)] pl-2 text-xs italic"
      >
        {@prose}
      </blockquote>
    </.peek>
    """
  end

  defp walkthrough_detail(d, lane) do
    steps = get(d, ["call_types", "walkthrough", "steps"])
    steps = if is_list(steps), do: steps, else: []

    case Enum.find(steps, &(is_map(&1) and &1["lane"] == lane)) do
      %{"detail" => %{} = detail} -> detail
      _other -> %{}
    end
  end
end
