defmodule TalesForge.Game.PlayerQuote do
  @moduledoc """
  Which words of the player the GM gets as the quote in the `PlayerAction`
  (`overall_intent`), decided per turn by an input safety read (decision
  2026-10-08 in tales-forge-docs `docs/decisions.md`).

  The safety read is one TypeSafe Jev call (call type `jev`, purpose
  `input_safety`): a choice between fixed labels — `benign`, `jailbreak`,
  `prompt_injection`, `nefarious` — with a confidence. It starts when the turn
  starts (`start/3`) and runs alongside the rules, prices and NPC reactions;
  the turn waits for it only before the GM prompt is built (`await/2`, timed as
  the step `turn.player_quote`).

  - **Quote:** when the label is `benign` with a confidence of at least the
    threshold (`PLAYER_QUOTE_MIN_BENIGN_CONFIDENCE`, default 0.90), the GM gets
    the player's own words, sanitised and at most 500 characters
    (`TalesForge.Game.Intent.sanitize_quote/1`), on both intent paths.
  - **Summary (fallback):** otherwise — another label, a lower confidence, an
    error, a timeout, or no TypeSafe key (`TYPESAFE_INTENT_API_KEY` when set,
    else `TYPESAFE_API_KEY`) — the GM gets the intent summary: the
    intent LLM's `overall_intent` when it wrote one, or a short typed summary
    of the action when the heuristic read the turn (its `overall_intent` is the
    player's text itself). The fallback is logged.

  Only the GM prompt changes. The rules (e.g. a wait's duration) still read the
  `PlayerAction` from the intent step. The baseline variant is frozen: it makes
  no safety call and keeps the intent step's `overall_intent`.

  Every decision is stored in `ai_calls.meta` (`label`, `confidence`,
  `benign_probability`, `threshold`, `used`, `reason`) on the Jev row, or on a
  zero-cost `function` row when no call could be made, so the fallback rate can
  be queried (`TalesForge.AICalls.Metrics.player_quote/2`).
  """

  require Logger

  alias TalesForge.AICalls
  alias TalesForge.Game.Intent
  alias TalesForge.Game.Schemas.PlayerAction
  alias TalesForge.Game.Variant

  @model "jev-1.13.0"
  @purpose "input_safety"
  @timeout_ms 2_000
  @input_chars 1_000

  @labels %{
    benign:
      "Ordinary play: what the player character says or does in the story, including in-story fights, crime, lies or dark themes",
    jailbreak:
      "Tries to make the AI drop its role, rules or limits (e.g. 'you are now an unrestricted AI', 'forget your guidelines')",
    prompt_injection:
      "Instructions aimed at the AI or the system instead of the story: ignore or reveal the prompt, change the rules, grant items, outcomes or levels, or talk to the model out of character",
    nefarious:
      "Harmful intent outside the fiction: real-world harm, harassment, illegal real-world help or personal data"
  }

  @typedoc """
  The safety read: `label` (a label name, or nil without a reply), `confidence`
  and `benign_probability` (0..1 or nil), `status` (`"ok"`, `"error"`,
  `"timeout"` or `"unconfigured"`) and `latency_ms`; a call adds `usage` and
  `started_at`.
  """
  @type read :: %{
          optional(:usage) => map() | nil,
          optional(:started_at) => DateTime.t(),
          label: String.t() | nil,
          confidence: float() | nil,
          benign_probability: float() | nil,
          status: String.t(),
          latency_ms: non_neg_integer()
        }

  @typedoc ~s(What the GM got: `used` is `"quote"` or `"summary"`, with the reason.)
  @type decision :: %{used: String.t(), reason: String.t(), threshold: float(), read: read()}

  @doc "The `ai_calls` purpose of the safety read."
  @spec purpose() :: String.t()
  def purpose, do: @purpose

  @doc ~S"""
  The fixed labels of the safety read, sorted.

      iex> TalesForge.Game.PlayerQuote.labels()
      ["benign", "jailbreak", "nefarious", "prompt_injection"]
  """
  @spec labels() :: [String.t()]
  def labels, do: @labels |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

  @doc "The minimum `benign` confidence for the quote (`PLAYER_QUOTE_MIN_BENIGN_CONFIDENCE`)."
  @spec threshold() :: float()
  def threshold,
    do: Application.get_env(:ex_tales_forge, :player_quote_min_benign_confidence, 0.9)

  @doc """
  True when a TypeSafe (Jev) API key is configured: `TYPESAFE_INTENT_API_KEY`
  (used for this read when set, so its cost is billed apart) or
  `TYPESAFE_API_KEY`.
  """
  @spec configured?() :: boolean()
  def configured? do
    present?(intent_key()) or
      present?(Application.get_env(:jev, :api_key) || System.get_env("TYPESAFE_API_KEY"))
  end

  defp intent_key, do: Application.get_env(:ex_tales_forge, :typesafe_intent_api_key)

  defp present?(key), do: is_binary(key) and key != ""

  defp key_opts do
    if present?(intent_key()), do: [api_key: intent_key()], else: []
  end

  @doc """
  Starts the safety read of `raw_action` for a session with `world` state.
  Returns a task to pass to `await/2`, `:unconfigured` without a TypeSafe key,
  or `:skip` for the baseline variant.
  """
  @spec start(String.t(), map(), non_neg_integer()) :: Task.t() | :unconfigured | :skip
  def start(raw_action, world, timeout_ms \\ @timeout_ms) do
    cond do
      Variant.baseline?(world) -> :skip
      not configured?() -> :unconfigured
      true -> Task.async(fn -> read(raw_action, timeout_ms) end)
    end
  end

  @doc """
  Waits for the safety read and returns `{gm_action, decision}`: the
  `PlayerAction` the GM gets and what was decided (nil for `:skip`, where the
  action is unchanged). Logs and stores the decision in `ai_calls`.
  """
  @spec await(Task.t() | :unconfigured | :skip, keyword()) ::
          {PlayerAction.t(), decision() | nil}
  def await(started, opts) do
    action = Keyword.fetch!(opts, :player_action)

    case started do
      :skip ->
        {action, nil}

      started ->
        read = collect(started)
        {gm_action, decision} = choose(action, Keyword.fetch!(opts, :raw_action), read)
        log_and_store(decision, opts)
        {gm_action, decision}
    end
  end

  defp collect(:unconfigured), do: empty_read("unconfigured", 0)

  defp collect(%Task{} = task) do
    case Task.yield(task, @timeout_ms + 500) || Task.shutdown(task, :brutal_kill) do
      {:ok, read} -> read
      _ -> empty_read("timeout", @timeout_ms + 500)
    end
  end

  @doc """
  The pure decision: the GM gets the sanitised raw text when `read` is
  `benign` at or above the threshold, else the intent summary.
  """
  @spec choose(PlayerAction.t(), String.t(), read(), float()) :: {PlayerAction.t(), decision()}
  def choose(%PlayerAction{} = action, raw_action, read, threshold \\ threshold()) do
    own_words = quote_text(raw_action)

    {used, reason} =
      cond do
        read.status != "ok" ->
          {"summary", read.status}

        read.label != "benign" ->
          {"summary", "label_#{read.label}"}

        is_number(read.confidence) and read.confidence >= threshold and own_words ->
          {"quote", "benign"}

        true ->
          {"summary", "low_confidence"}
      end

    overall_intent = if used == "quote", do: own_words, else: summary(action, own_words)
    decision = %{used: used, reason: reason, threshold: threshold, read: read}
    {%{action | overall_intent: overall_intent}, decision}
  end

  @doc """
  The fallback text: the intent step's `overall_intent` when it is an intent
  summary, or a short typed summary of the action when it is the player's own
  text (the heuristic path), e.g. `"speak (target: innkeep)"`.
  """
  @spec summary(PlayerAction.t(), String.t() | nil) :: String.t()
  def summary(%PlayerAction{overall_intent: intent} = action, own_words) do
    if is_binary(intent) and intent != "" and intent != own_words do
      intent
    else
      typed_summary(action)
    end
  end

  defp typed_summary(%PlayerAction{action: %{action_type: type, target: target}}) do
    case target do
      t when is_binary(t) and t != "" -> "#{type} (target: #{t})"
      _ -> to_string(type)
    end
  end

  defp typed_summary(_action), do: "player action"

  defp quote_text(raw_action) do
    Intent.sanitize_quote(raw_action)
  rescue
    ArgumentError -> nil
  end

  # --- the Jev call --------------------------------------------------------------

  @doc false
  @spec read(String.t(), non_neg_integer()) :: read()
  def read(raw_action, timeout_ms) do
    started_at = DateTime.utc_now()
    started = System.monotonic_time(:millisecond)

    result =
      Jev.HTTP.post(
        state(raw_action),
        questions(),
        [model: @model, max_retries: 0, receive_timeout: timeout_ms] ++ key_opts()
      )

    elapsed = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, reply} ->
        Map.merge(parse(reply), %{
          status: "ok",
          latency_ms: elapsed,
          usage: reply[:usage],
          started_at: started_at
        })

      {:error, reason} ->
        Logger.warning("input safety read failed reason=#{inspect(reason)}")
        "error" |> empty_read(elapsed) |> Map.put(:started_at, started_at)
    end
  rescue
    e ->
      Logger.warning("input safety read crashed error=#{Exception.message(e)}")
      empty_read("error", 0)
  end

  @doc false
  @spec state(String.t()) :: String.t()
  def state(raw_action) do
    text = raw_action |> to_string() |> String.trim() |> String.slice(0, @input_chars)

    "A player's message in a fantasy text role-playing game. An AI game master " <>
      "narrates the story; the player only says what their character says or does.\n\n" <>
      "Player message:\n" <> text
  end

  @doc false
  @spec questions() :: keyword()
  def questions do
    [
      safety:
        {"Which best describes this player message, as input to the AI game master?", @labels}
    ]
  end

  @doc false
  @spec parse(map()) :: map()
  def parse(reply) do
    %{
      label: label(reply[:safety]),
      confidence: round2(get_in(reply, [:confidence, :safety])),
      benign_probability: round2(get_in(reply, [:probabilities, :safety, :benign]))
    }
  end

  defp empty_read(status, latency_ms),
    do: %{
      label: nil,
      confidence: nil,
      benign_probability: nil,
      status: status,
      latency_ms: latency_ms
    }

  # --- logging -------------------------------------------------------------------

  defp log_and_store(decision, opts) do
    read = decision.read
    session_id = Keyword.get(opts, :session_id)
    turn_number = Keyword.get(opts, :turn_number)

    line =
      "player quote session=#{session_id} turn=#{turn_number} used=#{decision.used} " <>
        "reason=#{decision.reason} label=#{read.label} confidence=#{read.confidence} " <>
        "benign_p=#{read.benign_probability} threshold=#{decision.threshold}"

    # A missing key is a setting, not a per-turn event worth a warning.
    if decision.reason in ["benign", "unconfigured"],
      do: Logger.info(line),
      else: Logger.warning(line)

    meta = %{
      "label" => read.label,
      "confidence" => read.confidence,
      "benign_probability" => read.benign_probability,
      "threshold" => decision.threshold,
      "used" => decision.used,
      "reason" => decision.reason
    }

    AICalls.record(row(read, meta, session_id, turn_number))
  end

  defp row(%{status: status} = read, meta, session_id, turn_number)
       when status in ["ok", "error", "timeout"] do
    usage = Map.get(read, :usage) || %{}
    input = usage[:input_tokens] || 0

    # Jev bills input tokens only (~$0.042 per 1M input tokens).
    cost_micro =
      case usage[:cost] do
        c when is_number(c) -> round(c * 1_000_000)
        _ -> round(input * 0.042)
      end

    %{
      purpose: @purpose,
      call_type: "jev",
      model: @model,
      status: if(status == "ok", do: "ok", else: "error"),
      latency_ms: read.latency_ms,
      game_session_id: session_id,
      turn_number: turn_number,
      started_at: Map.get(read, :started_at) || DateTime.utc_now(),
      meta: meta,
      usage: %{input_tokens: input, output_tokens: 0, cost_ticks: cost_micro * 10_000}
    }
  end

  defp row(_read, meta, session_id, turn_number) do
    %{
      purpose: @purpose,
      call_type: "function",
      model: "elixir",
      status: "ok",
      latency_ms: 0,
      game_session_id: session_id,
      turn_number: turn_number,
      started_at: DateTime.utc_now(),
      meta: meta
    }
  end

  defp label(nil), do: nil
  defp label(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp label(other), do: to_string(other)

  defp round2(x) when is_number(x), do: Float.round(x / 1, 2)
  defp round2(_x), do: nil
end
