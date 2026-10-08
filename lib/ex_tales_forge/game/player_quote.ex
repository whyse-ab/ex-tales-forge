defmodule TalesForge.Game.PlayerQuote do
  @moduledoc """
  Which words of the player the GM gets as the quote in the `PlayerAction`
  (`overall_intent`), decided per turn from the intent call's input safety read
  (decisions 2026-10-08 in tales-forge-docs `docs/decisions.md`).

  The safety read is part of the Tier 1 intent call, not a call of its own: in
  the default variant its schema (`TalesForge.LLM.intent_schema/1`) has
  `input_safety`, one of the fixed labels `benign`, `jailbreak`,
  `prompt_injection` and `nefarious`, and `input_safety_confidence` (0..1);
  `intent_system.txt` says how to fill them.

  - **Quote:** when the intent call labels the message `benign` with a
    confidence of at least the threshold (`PLAYER_QUOTE_MIN_BENIGN_CONFIDENCE`,
    default 0.90), the GM gets the player's own words, sanitised and at most
    500 characters (`TalesForge.Game.Intent.sanitize_quote/1`).
  - **Summary (fallback):** otherwise the GM gets the intent summary: the
    intent call's `overall_intent`, or a short typed summary of the action
    (`"speak (target: innkeep)"`) when there is no intent summary. Fallback
    reasons: another label, a lower confidence, no safety fields in the reply,
    a turn that needs clarification first, or no intent call at all.
  - **No intent call** (the heuristic was confident, the intent call failed,
    or the player picked a clarification option): there is no safety read, so
    the GM gets the typed summary. `INTENT_CALL_EVERY_TURN=on` sends every
    default-variant turn through the intent call instead, so every turn has a
    safety read (costs one intent call per turn).

  Only the GM prompt's quote changes (`TalesForge.Game.TurnProcessor`, job arg
  `gm_quote`); the rules still read the intent step's `PlayerAction`. The
  baseline variant is frozen: no safety fields, no decision, no `gm_quote`.

  Every decision is logged and stored in `ai_calls.meta` (`label`,
  `confidence`, `threshold`, `used`, `reason`): on the intent call's row, and on
  the turn's `turn.intent` step row, which exists for every message, so the
  fallback rate covers every turn (`TalesForge.AICalls.Metrics.player_quote/2`).
  """

  require Logger

  alias TalesForge.Game.Intent
  alias TalesForge.Game.Schemas.{IntentExtraction, PlayerAction}

  @labels ~w(benign jailbreak prompt_injection nefarious)

  @typedoc """
  What the GM gets: `quote` (the text for `overall_intent`), `used`
  (`"quote"` or `"summary"`), `reason`, and the safety read it came from.
  """
  @type decision :: %{
          quote: String.t(),
          used: String.t(),
          reason: String.t(),
          label: String.t() | nil,
          confidence: float() | nil,
          threshold: float()
        }

  @doc ~S"""
  The fixed labels of the safety read.

      iex> TalesForge.Game.PlayerQuote.labels()
      ["benign", "jailbreak", "prompt_injection", "nefarious"]
  """
  @spec labels() :: [String.t()]
  def labels, do: @labels

  @doc "The minimum `benign` confidence for the quote (`PLAYER_QUOTE_MIN_BENIGN_CONFIDENCE`)."
  @spec threshold() :: float()
  def threshold,
    do: Application.get_env(:ex_tales_forge, :player_quote_min_benign_confidence, 0.9)

  @doc """
  Decides the GM's quote for a validated `action` read from `raw_action`.
  `extraction` is the intent call's reply, or nil when no intent call read the
  turn (`source` says why: `:heuristic`, `:clarification`).
  """
  @spec decide(PlayerAction.t(), String.t(), IntentExtraction.t() | nil, atom(), float()) ::
          decision()
  def decide(%PlayerAction{} = action, raw_action, extraction, source, threshold \\ threshold()) do
    own_words = own_words(raw_action)
    {label, confidence} = read(extraction)

    {used, reason} =
      cond do
        is_nil(extraction) -> {"summary", "no_intent_call_#{source}"}
        is_nil(label) -> {"summary", "no_safety_read"}
        label != "benign" -> {"summary", "label_#{label}"}
        not is_number(confidence) or confidence < threshold -> {"summary", "low_confidence"}
        is_nil(own_words) -> {"summary", "empty_text"}
        true -> {"quote", "benign"}
      end

    %{
      quote: if(used == "quote", do: own_words, else: summary(action, own_words)),
      used: used,
      reason: reason,
      label: label,
      confidence: confidence,
      threshold: threshold
    }
  end

  @doc """
  The `ai_calls.meta` of an intent call's decoded JSON reply: the safety read
  and what it means for the quote (before validation; a reply that needs
  clarification gets no quote).
  """
  @spec reply_meta(map(), String.t()) :: map()
  def reply_meta(%{} = reply, raw_action) do
    extraction = IntentExtraction.decode(reply)
    action = %PlayerAction{overall_intent: extraction.overall_intent, action: nil}
    decided = decide(action, raw_action, extraction, :llm)

    if extraction.needs_clarification,
      do: meta(%{decided | used: "summary", reason: "needs_clarification"}),
      else: meta(decided)
  end

  @doc "The `ai_calls.meta` map of a decision."
  @spec meta(decision()) :: map()
  def meta(decision) do
    %{
      "label" => decision.label,
      "confidence" => decision.confidence,
      "threshold" => decision.threshold,
      "used" => decision.used,
      "reason" => decision.reason
    }
  end

  @doc "Logs the decision for a turn (warning for a fallback after a safety read)."
  @spec log(decision(), String.t(), integer()) :: :ok
  def log(decision, session_id, turn_number) do
    line =
      "player quote session=#{session_id} turn=#{turn_number} used=#{decision.used} " <>
        "reason=#{decision.reason} label=#{decision.label} " <>
        "confidence=#{decision.confidence} threshold=#{decision.threshold}"

    if decision.used == "summary" and decision.label != nil,
      do: Logger.warning(line),
      else: Logger.info(line)
  end

  @doc """
  The fallback text: the intent summary when there is one, else a short typed
  summary of the action, e.g. `"speak (target: innkeep)"`. An `overall_intent`
  that is the player's own text (the heuristic's) is not a summary.
  """
  @spec summary(PlayerAction.t(), String.t() | nil) :: String.t()
  def summary(%PlayerAction{overall_intent: intent} = action, own_words) do
    if is_binary(intent) and String.trim(intent) != "" and intent != own_words,
      do: intent,
      else: typed_summary(action)
  end

  defp typed_summary(%PlayerAction{action: %{action_type: type, target: target}}) do
    case target do
      t when is_binary(t) and t != "" -> "#{type} (target: #{t})"
      _ -> to_string(type)
    end
  end

  defp typed_summary(_action), do: "player action"

  defp read(nil), do: {nil, nil}

  defp read(%IntentExtraction{safety: label, safety_confidence: confidence}) do
    label = if label in @labels, do: label
    confidence = if is_number(confidence), do: Float.round(confidence / 1, 2)
    {label, confidence}
  end

  defp own_words(raw_action) do
    Intent.sanitize_quote(raw_action)
  rescue
    ArgumentError -> nil
  end
end
