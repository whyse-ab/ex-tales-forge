defmodule TalesForge.IntentJev do
  @moduledoc """
  The player-intent read as one TypeSafe Jev call, wired into live turns behind
  `INTENT_JEV` (tales-forge-docs `docs/design-jev-intent.md`).

  The mode is fixed per session when it is created and stored as
  `world_state["intent_jev"]` (only when it is not `off`), like the other
  "new sessions" flags; the baseline variant is always `off`
  (`mode_for_new_session/2`, `mode/1`):

    * `:off` — today's intent path (heuristic, Tier 1 LLM when unsure). Nothing
      here runs.
    * `:shadow` — today's path plays, unchanged. After it has decided, the Jev
      read runs in a background task and is only logged (`shadow/4`): the
      call's own `ai_calls` row (call type `jev`, purpose `intent_shadow`:
      cost, latency, status) and a `turn.intent_shadow` function row whose
      `meta` holds Jev's reading, its band and safety label, the quote it would
      pick, today's reading, and the diff between the two. The job args, the
      `PlayerAction` and the GM prompt are exactly what `:off` produces.
    * `:on` — the Jev read drives the turn (`resolve/4`): act at a calibrated
      confidence ≥ `INTENT_ACT_MIN_CONFIDENCE`, ask below
      `INTENT_ASK_BELOW_CONFIDENCE` only when the top two readings would play
      out differently, best guess in between; at most one templated question
      per turn (`TalesForge.Game.IntentClarification`). The safety label sets
      the GM's quote (`TalesForge.Game.PlayerQuote`); `nefarious` is declined
      by the GM in character. On a Jev error, a timeout
      (`INTENT_JEV_TIMEOUT_MS`) or no key, the heuristic reads the turn and the
      GM gets the typed summary.

  The call uses the named Jev endpoint `:intent` (`TYPESAFE_INTENT_API_KEY`,
  `config/runtime.exs`), no retries, and is recorded in `ai_calls` (call type
  `jev`, purpose `intent` or `intent_shadow`). The `turn.intent` step row's
  `meta` holds the decision in `:on`.
  """

  require Logger

  alias TalesForge.AICalls
  alias TalesForge.Config
  alias TalesForge.Game.{Intent, IntentClarification, JevIntent, NpcReactions, PlayerQuote}
  alias TalesForge.Game.Schemas.{PlayerAction, SingleAction}

  @model "jev-1.13.0"
  @modes ~w(off shadow on)
  @text_chars 600
  # Headroom over the receive timeout for the hard deadline in post_within/3.
  @deadline_slack_ms 100
  # The shadow read is off the player's clock, so it waits longer than the live
  # timeout and logs whether it would have made it (`within_live_timeout`).
  @shadow_timeout_ms 10_000

  @typedoc "The Jev intent mode of a session."
  @type mode :: :off | :shadow | :on

  @typedoc """
  The outcome of `resolve/4` in `:on` mode: play `action` (with the GM's
  `gm_quote` and an optional `gm_note`), or ask with `clarification`. `meta`
  goes on the turn's `turn.intent` row either way.
  """
  @type outcome ::
          {:act, PlayerAction.t(), %{gm_quote: String.t(), gm_note: String.t() | nil}, map()}
          | {:ask, map(), map()}

  @typedoc "Today's reading, for the shadow diff: the played action, or the question it asked."
  @type current :: %{
          source: atom(),
          action: PlayerAction.t() | nil,
          clarification: boolean()
        }

  # --- mode ----------------------------------------------------------------------

  @doc """
  The mode a new session gets: `override` (`"off"`, `"shadow"` or `"on"`, e.g.
  a playtest run's arm) when given, else `INTENT_JEV`. Always `:off` for the
  baseline variant.
  """
  @spec mode_for_new_session(String.t() | nil, String.t() | atom() | nil) :: mode()
  def mode_for_new_session("baseline", _override), do: :off

  def mode_for_new_session(_variant, override) do
    case parse_mode(override) do
      nil -> Config.intent_jev_mode()
      mode -> mode
    end
  end

  @doc ~S"""
  A mode from its name, or nil for anything else.

      iex> TalesForge.IntentJev.parse_mode("shadow")
      :shadow
      iex> TalesForge.IntentJev.parse_mode("loud")
      nil
  """
  @spec parse_mode(String.t() | atom() | nil) :: mode() | nil
  def parse_mode(mode) when mode in [:off, :shadow, :on], do: mode

  def parse_mode(mode) when is_binary(mode) do
    case mode |> String.trim() |> String.downcase() do
      m when m in @modes -> String.to_existing_atom(m)
      _ -> nil
    end
  end

  def parse_mode(_mode), do: nil

  @doc ~S"""
  Stores `mode` in a new session's world state: nothing for `:off`, so an
  `off` world state is exactly today's.

      iex> TalesForge.IntentJev.put_mode(%{}, :off)
      %{}
      iex> TalesForge.IntentJev.put_mode(%{}, :shadow)
      %{"intent_jev" => "shadow"}
  """
  @spec put_mode(map(), mode()) :: map()
  def put_mode(world, :off), do: world
  def put_mode(world, mode), do: Map.put(world, "intent_jev", Atom.to_string(mode))

  @doc ~S"""
  The mode of a session's world state (or intent context). `:off` for the
  baseline variant and for sessions created without one.

      iex> TalesForge.IntentJev.mode(%{"intent_jev" => "on"})
      :on
      iex> TalesForge.IntentJev.mode(%{"intent_jev" => "on", "variant" => "baseline"})
      :off
      iex> TalesForge.IntentJev.mode(%{})
      :off
  """
  @spec mode(map() | nil) :: mode()
  def mode(%{"variant" => "baseline"}), do: :off
  def mode(%{"intent_jev" => mode}), do: parse_mode(mode) || :off
  def mode(_world), do: :off

  @doc "True when the `:intent` Jev endpoint has a key (`TYPESAFE_INTENT_API_KEY`)."
  @spec configured?() :: boolean()
  def configured? do
    case Application.get_env(:jev, :endpoints, [])[:intent][:api_key] do
      key when is_binary(key) -> String.trim(key) != ""
      _ -> false
    end
  end

  # --- the call ----------------------------------------------------------------

  @doc """
  One Jev intent read of `text` over the live intent `context`, recorded in
  `ai_calls` (purpose `opts[:purpose]`, default `"intent"`). Adds the last GM
  narration to the context when it has none. Returns `{:ok, reading,
  candidates, latency_ms}` or `{:error, reason}` (`:no_key`, `:timeout` or
  another error); never raises.
  """
  @spec read(map(), String.t(), keyword()) ::
          {:ok, JevIntent.reading(), [JevIntent.candidate()], non_neg_integer()}
          | {:error, atom()}
  def read(context, text, opts \\ []) do
    if configured?(), do: do_read(context, text, opts), else: {:error, :no_key}
  end

  defp do_read(context, text, opts) do
    purpose = Keyword.get(opts, :purpose, "intent")
    session_id = context["session_id"]
    context = with_narration(context)
    candidates = JevIntent.candidates(context)
    started_at = DateTime.utc_now()
    started = System.monotonic_time(:millisecond)

    timeout = Keyword.get(opts, :timeout_ms) || Config.intent_jev_timeout_ms()
    state = JevIntent.state(context, text)
    questions = JevIntent.questions(candidates)
    result = post_within(state, questions, timeout)

    elapsed = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, reply} ->
        reading = JevIntent.decode(reply, candidates, text: text, context: context)
        record_call(purpose, "ok", elapsed, started_at, context, reply)
        {:ok, reading, candidates, elapsed}

      {:error, error} ->
        reason = error_reason(error)
        record_call(purpose, "error", elapsed, started_at, context, %{})

        Logger.warning(
          "jev intent failed session=#{session_id} purpose=#{purpose} reason=#{reason} duration_ms=#{elapsed}"
        )

        {:error, reason}
    end
  rescue
    e ->
      Logger.error("jev intent crashed error=#{Exception.message(e)}")
      {:error, :crashed}
  end

  # The receive timeout alone does not bound connecting or a stalled pool, so
  # the whole call also runs under a hard deadline on the player's clock.
  defp post_within(state, questions, timeout) do
    task =
      Task.Supervisor.async_nolink(TalesForge.IntentJev.Supervisor, fn ->
        Jev.HTTP.post(state, questions,
          endpoint: :intent,
          model: @model,
          max_retries: 0,
          receive_timeout: timeout
        )
      end)

    case Task.yield(task, timeout + @deadline_slack_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, :crashed}
      nil -> {:error, %{reason: :timeout}}
    end
  end

  defp with_narration(%{"last_narration" => text} = context) when is_binary(text), do: context

  defp with_narration(%{"session_id" => id} = context) when is_binary(id),
    do: Map.put(context, "last_narration", NpcReactions.last_narration(id))

  defp with_narration(context), do: context

  defp error_reason(:crashed), do: :crashed
  defp error_reason(%{reason: :timeout}), do: :timeout
  defp error_reason(%Req.TransportError{reason: :timeout}), do: :timeout
  defp error_reason(%{status: status}) when is_integer(status), do: :http_error
  defp error_reason(_error), do: :error

  defp record_call(purpose, status, latency_ms, started_at, context, reply) do
    usage = Map.get(reply, :usage) || %{}
    input = usage[:input_tokens] || 0

    # Jev bills input tokens only (~$0.042 per 1M input tokens).
    cost_micro =
      case usage[:cost] do
        c when is_number(c) -> round(c * 1_000_000)
        _ -> round(input * 0.042)
      end

    AICalls.record(%{
      purpose: purpose,
      call_type: "jev",
      model: Map.get(reply, :model) || @model,
      status: status,
      latency_ms: latency_ms,
      started_at: started_at,
      game_session_id: context["session_id"],
      turn_number: context["turn_number"],
      usage: %{input_tokens: input, output_tokens: 0, cost_ticks: cost_micro * 10_000}
    })
  end

  # --- on ------------------------------------------------------------------------

  @doc """
  `:on` mode: reads `raw_action` with Jev and decides the turn.

  `opts`:

    * `:never_ask` — true for a free-text answer to a question: the read plays
      its best guess and never asks again (one round per turn);
    * `:act_min`, `:ask_below`, `:quote_threshold` — override the config.

  On a Jev error or timeout the heuristic reads the text and the GM gets the
  typed summary. Raises what `TalesForge.Game.Intent.validate_player_action/2`
  raises for an unusable action.
  """
  @spec resolve(map(), String.t(), keyword()) :: outcome()
  def resolve(context, raw_action, opts \\ []) do
    case read(context, raw_action) do
      {:ok, reading, candidates, latency} ->
        decide(reading, candidates, context, raw_action, latency, opts)

      {:error, reason} ->
        fallback(context, raw_action, reason)
    end
  end

  @doc """
  The decision for a Jev `reading` (see `resolve/3`): pure apart from the
  clarification id. Exposed for tests and the eval.
  """
  @spec decide(
          JevIntent.reading(),
          [JevIntent.candidate()],
          map(),
          String.t(),
          non_neg_integer(),
          keyword()
        ) :: outcome()
  def decide(reading, candidates, context, raw_action, latency_ms, opts \\ []) do
    band_opts = [
      act_min: Keyword.get(opts, :act_min, Config.intent_act_min_confidence()),
      ask_below: Keyword.get(opts, :ask_below, Config.intent_ask_below_confidence())
    ]

    band =
      case IntentClarification.band(reading, band_opts) do
        :ask -> if(Keyword.get(opts, :never_ask, false), do: :best_guess, else: :ask)
        other -> other
      end

    safety = safety(reading)
    base_meta = reading_meta(reading, band, latency_ms)

    cond do
      PlayerQuote.decline?(safety) ->
        decline(context, raw_action, safety, base_meta, opts)

      band == :ask ->
        clarification =
          reading
          |> IntentClarification.build(candidates)
          |> Map.put("raw_action", raw_action)
          |> Map.put("safety", safety_map(safety))

        {:ask, clarification, Map.merge(base_meta, %{"source" => "jev", "asked" => true})}

      true ->
        action = Intent.validate_player_action(reading.extraction, context)
        quote = PlayerQuote.decide(action, raw_action, safety, quote_threshold(opts))
        meta = Map.merge(base_meta, %{"source" => "jev", "quote" => PlayerQuote.meta(quote)})
        log_decision(context, band, quote, reading)
        {:act, action, %{gm_quote: quote.quote, gm_note: nil}, meta}
    end
  end

  @doc """
  `:on` mode, a clicked option of a Jev question: plays that option's typed
  reading (no call). `pending` is the stored clarification.
  """
  @spec resolve_option(map(), map(), map()) :: outcome()
  def resolve_option(pending, option, context) do
    actions =
      pending
      |> Map.get("option_actions", [])
      |> Enum.at(option["action_index"] || 0)
      |> List.wrap()
      |> Enum.map(&SingleAction.decode/1)

    extraction = %TalesForge.Game.Schemas.IntentExtraction{
      overall_intent: pending["overall_intent"] || pending["raw_action"] || "",
      actions: if(actions == [], do: [%SingleAction{action_type: :other}], else: actions),
      primary_index: 0,
      confidence: 1.0,
      needs_clarification: false
    }

    action = Intent.validate_player_action(extraction, context)
    safety = pending |> Map.get("safety") |> safety_from_map()

    quote =
      PlayerQuote.decide(
        action,
        pending["raw_action"] || "",
        safety,
        Config.player_quote_min_benign_confidence()
      )

    meta = %{
      "mode" => "on",
      "source" => "clarification_option",
      "option" => option["id"],
      "quote" => PlayerQuote.meta(quote)
    }

    {:act, action, %{gm_quote: quote.quote, gm_note: nil}, meta}
  end

  # Jev failed: the heuristic reads the text; no safety read, so a summary.
  defp fallback(context, raw_action, reason) do
    extraction = Intent.heuristic_intent(raw_action, context)
    action = Intent.validate_player_action(extraction, context)

    quote =
      PlayerQuote.decide(
        action,
        raw_action,
        nil,
        Config.player_quote_min_benign_confidence(),
        "jev_#{reason}"
      )

    meta = %{
      "mode" => "on",
      "source" => "heuristic_fallback",
      "jev_status" => Atom.to_string(reason),
      "quote" => PlayerQuote.meta(quote)
    }

    Logger.info(
      "jev intent fallback session=#{context["session_id"]} reason=#{reason} used=summary"
    )

    {:act, action, %{gm_quote: quote.quote, gm_note: nil}, meta}
  end

  # A request for real-world harm: no mechanics (the action becomes `other`
  # with no target, skill or plan), the GM gets the typed summary and a note to
  # decline in character, and the turn still resolves.
  defp decline(context, raw_action, safety, base_meta, opts) do
    extraction = %TalesForge.Game.Schemas.IntentExtraction{
      overall_intent: raw_action,
      actions: [%SingleAction{action_type: :other}],
      primary_index: 0,
      confidence: 1.0,
      needs_clarification: false
    }

    action = Intent.validate_player_action(extraction, context)
    quote = PlayerQuote.decide(action, raw_action, safety, quote_threshold(opts))

    meta =
      Map.merge(base_meta, %{
        "source" => "jev",
        "declined" => true,
        "quote" => PlayerQuote.meta(quote)
      })

    Logger.warning(
      "jev intent declined session=#{context["session_id"]} label=nefarious confidence=#{inspect(safety.confidence)}"
    )

    {:act, action, %{gm_quote: quote.quote, gm_note: "decline_nefarious"}, meta}
  end

  defp quote_threshold(opts),
    do: Keyword.get(opts, :quote_threshold, Config.player_quote_min_benign_confidence())

  # A flagged message (jailbreak, prompt injection) is a warning: play goes on
  # in-story with the typed summary, but someone should be able to find it.
  defp log_decision(context, band, quote, reading) do
    level = if reading.safety == :benign, do: :info, else: :warning

    Logger.log(
      level,
      "jev intent session=#{context["session_id"]} band=#{band} action=#{reading.action} " <>
        "confidence=#{inspect(reading.confidence)} used=#{quote.used} reason=#{quote.reason} " <>
        "label=#{quote.label}"
    )
  end

  # --- shadow --------------------------------------------------------------------

  @doc """
  `:shadow` mode: after today's path has decided (`current`), reads the same
  text with Jev and logs the reading and the diff in the `meta` of a
  `turn.intent_shadow` row (the call itself has its own `intent_shadow` row). Runs in a background task (`:sync` in tests, config
  `:intent_jev_shadow`), so it adds nothing to the player's clock, and it never
  raises into the turn. It waits up to 10 s (`opts[:timeout_ms]`) rather than
  the live `INTENT_JEV_TIMEOUT_MS`, and records `within_live_timeout`, so one
  shadow day gives both the agreement and the fallback rate `on` would see.
  Always `:ok`.
  """
  @spec shadow(map(), String.t(), current(), keyword()) :: :ok
  def shadow(context, raw_action, current, opts \\ []) do
    fun = fn -> run_shadow(context, raw_action, current, opts) end

    case Application.get_env(:ex_tales_forge, :intent_jev_shadow, :async) do
      :sync -> fun.()
      _ -> Task.Supervisor.start_child(TalesForge.IntentJev.Supervisor, fun)
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc false
  @spec run_shadow(map(), String.t(), current(), keyword()) :: :ok
  def run_shadow(context, raw_action, current, opts \\ []) do
    meta =
      case read(context, raw_action,
             purpose: "intent_shadow",
             timeout_ms: opts[:timeout_ms] || @shadow_timeout_ms
           ) do
        {:ok, reading, _candidates, latency} ->
          reading
          |> shadow_meta(latency, context, raw_action, current)
          |> Map.put("within_live_timeout", latency <= Config.intent_jev_timeout_ms())

        {:error, reason} ->
          %{"mode" => "shadow", "status" => Atom.to_string(reason)}
      end
      |> Map.put("text", raw_action |> to_string() |> String.slice(0, @text_chars))
      |> Map.put("current", current_meta(current))

    record_shadow(context, meta)

    Logger.info(
      "jev intent shadow session=#{context["session_id"]} status=#{meta["status"]} " <>
        "same_action=#{inspect(get_in(meta, ["diff", "action"]))}"
    )

    :ok
  rescue
    e ->
      Logger.warning("jev intent shadow crashed error=#{Exception.message(e)}")
      :ok
  end

  defp shadow_meta(reading, latency, context, raw_action, current) do
    band = IntentClarification.band(reading, band_opts())
    safety = safety(reading)
    jev_action = safe_validate(reading.extraction, context)

    quote =
      jev_action &&
        PlayerQuote.decide(
          jev_action,
          raw_action,
          safety,
          Config.player_quote_min_benign_confidence()
        )

    reading_meta(reading, band, latency)
    |> Map.merge(%{
      "mode" => "shadow",
      "status" => "ok",
      "would_decline" => PlayerQuote.decline?(safety),
      "quote" => quote && PlayerQuote.meta(quote),
      "jev_action" => jev_action && PlayerAction.encode(jev_action),
      "diff" => diff(jev_action, band, current)
    })
  end

  defp band_opts do
    [
      act_min: Config.intent_act_min_confidence(),
      ask_below: Config.intent_ask_below_confidence()
    ]
  end

  defp safe_validate(extraction, context) do
    Intent.validate_player_action(extraction, context)
  rescue
    _ -> nil
  end

  defp record_shadow(context, meta) do
    # The shadow's own Jev row (cost, latency) is written by read/3; this
    # function row carries the comparison for the turn.
    AICalls.record(%{
      purpose: "turn.intent_shadow",
      call_type: "function",
      model: "elixir",
      status: "ok",
      latency_ms: 0,
      game_session_id: context["session_id"],
      turn_number: context["turn_number"],
      meta: meta
    })
  end

  @doc """
  The field-by-field diff between Jev's validated action and today's: `true`
  where they agree. `class` compares consequence classes
  (`TalesForge.Game.IntentClarification.class/1`); `material` is true when the
  two would play out differently (another class, or another move or fight
  target). `asked` is whether each path would ask the player.
  """
  @spec diff(PlayerAction.t() | nil, IntentClarification.decision(), current()) :: map()
  def diff(nil, band, current) do
    %{
      "jev_valid" => false,
      "asked" => %{"jev" => band == :ask, "current" => current.clarification}
    }
  end

  def diff(%PlayerAction{} = jev, band, %{action: nil} = current) do
    %{
      "jev_valid" => true,
      "jev_action" => Atom.to_string(jev.action.action_type),
      "asked" => %{"jev" => band == :ask, "current" => current.clarification}
    }
  end

  def diff(%PlayerAction{} = jev, band, %{action: %PlayerAction{} = cur} = current) do
    a = jev.action
    b = cur.action

    same_class =
      IntentClarification.class(a.action_type) == IntentClarification.class(b.action_type)

    %{
      "jev_valid" => true,
      "action" => a.action_type == b.action_type,
      "class" => same_class,
      "target" => a.target == b.target,
      "skill" => skill(a) == skill(b),
      "later" => laters(jev) == laters(cur),
      "material" =>
        not same_class or
          (a.action_type in [:move, :combat] and a.action_type == b.action_type and
             a.target != b.target),
      "asked" => %{"jev" => band == :ask, "current" => current.clarification}
    }
  end

  defp skill(%SingleAction{parameters: params}) when is_map(params), do: params["skill"]
  defp skill(_action), do: nil

  defp laters(%PlayerAction{deferred_actions: deferred}) do
    Enum.map(deferred || [], fn d -> {d.action_type, d.target} end)
  end

  defp current_meta(%{action: %PlayerAction{} = action} = current) do
    %{
      "source" => to_string(current.source),
      "clarification" => current.clarification,
      "action" => PlayerAction.encode(action)
    }
  end

  defp current_meta(current) do
    %{"source" => to_string(current.source), "clarification" => current.clarification}
  end

  # --- shared ----------------------------------------------------------------------

  defp safety(reading) do
    %{
      label: reading.safety,
      confidence: reading.safety_confidence,
      benign_probability: reading.benign_probability
    }
  end

  defp safety_map(safety) do
    %{
      "label" => safety.label && Atom.to_string(safety.label),
      "confidence" => safety.confidence,
      "benign_probability" => safety.benign_probability
    }
  end

  defp safety_from_map(%{"label" => label} = map) when is_binary(label) do
    %{
      label: if(label in PlayerQuote.labels(), do: String.to_existing_atom(label)),
      confidence: map["confidence"],
      benign_probability: map["benign_probability"]
    }
  end

  defp safety_from_map(_map), do: nil

  @doc """
  The reading as string-keyed `ai_calls.meta`: the typed reading, its raw and
  calibrated confidence, the top action probabilities, the band, the safety
  label and the calibration version.
  """
  @spec reading_meta(JevIntent.reading(), IntentClarification.decision(), non_neg_integer()) ::
          map()
  def reading_meta(reading, band, latency_ms) do
    %{
      "mode" => "on",
      "band" => Atom.to_string(band),
      "action" => Atom.to_string(reading.action),
      "target" => reading.target,
      "skill" => reading.skill,
      "later" => reading.later && Atom.to_string(reading.later),
      "later_target" => reading.later_target,
      "confidence" => reading.confidence,
      "raw_confidence" => Map.get(reading, :raw_confidence),
      "top2" =>
        reading.action_probabilities
        |> Enum.sort_by(fn {_label, p} -> -p end)
        |> Enum.take(2)
        |> Enum.map(fn {label, p} -> [Atom.to_string(label), Float.round(p / 1, 4)] end),
      "safety" => %{
        "label" => Atom.to_string(reading.safety),
        "confidence" => reading.safety_confidence,
        "benign_probability" => reading.benign_probability
      },
      "calibration" => Map.get(reading, :calibration),
      "latency_ms" => latency_ms,
      "cost_usd" => reading.cost
    }
  end
end
