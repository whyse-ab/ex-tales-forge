defmodule TalesForge.Game.PlayerQuote do
  @moduledoc """
  Which words of the player the GM gets as the quote in the `PlayerAction`
  (`overall_intent`), decided per turn from the Jev intent read's safety label
  (tales-forge-docs `docs/design-jev-intent.md` §4).

  - **Quote:** label `benign` with a confidence of at least the threshold
    (`PLAYER_QUOTE_MIN_BENIGN_CONFIDENCE`, default 0.90): the GM gets the
    player's own words, sanitised and at most 500 characters
    (`TalesForge.Game.Intent.sanitize_quote/1`).
  - **Summary:** anything else (another label, a lower confidence, no read
    because Jev failed or timed out): the GM gets a short typed summary of the
    action, such as `"speak (target: innkeep)"`.

  A safety label never asks the player and never changes the rules. Only
  `nefarious` changes the turn (`decline?/1`): the GM declines in character.
  Used only when `INTENT_JEV=on` (`TalesForge.IntentJev`); the quote reaches the
  GM prompt through the turn job's `gm_quote`, so the rules still read the
  `PlayerAction` itself.
  """

  alias TalesForge.Game.Intent
  alias TalesForge.Game.Schemas.{PlayerAction, SingleAction}

  @labels ~w(benign jailbreak prompt_injection nefarious)

  @typedoc """
  The decision: `quote` (the text for the GM's `overall_intent`), `used`
  (`"quote"` or `"summary"`), `reason`, and the safety read it came from.
  """
  @type decision :: %{
          quote: String.t(),
          used: String.t(),
          reason: String.t(),
          label: String.t() | nil,
          confidence: float() | nil,
          benign_probability: float() | nil,
          threshold: float()
        }

  @typedoc "A safety read: the top label, its confidence and P(benign); nil when there was none."
  @type safety :: %{
          label: atom() | nil,
          confidence: float() | nil,
          benign_probability: float() | nil
        }

  @doc ~S"""
  The fixed labels of the safety read.

      iex> TalesForge.Game.PlayerQuote.labels()
      ["benign", "jailbreak", "prompt_injection", "nefarious"]
  """
  @spec labels() :: [String.t()]
  def labels, do: @labels

  @doc """
  Decides the GM's quote for `action`, read from the player's `raw_action`,
  given the `safety` read (nil when there was none; `no_read_reason` then
  names why, e.g. `"jev_timeout"`).
  """
  @spec decide(PlayerAction.t(), String.t(), safety() | nil, float(), String.t()) :: decision()
  def decide(%PlayerAction{} = action, raw_action, safety, threshold, no_read_reason \\ "no_read") do
    own_words = own_words(raw_action)
    label = safety && safety.label && Atom.to_string(safety.label)
    confidence = safety && safety.confidence

    {used, reason} =
      cond do
        is_nil(safety) -> {"summary", no_read_reason}
        label != "benign" -> {"summary", "label_#{label}"}
        not is_number(confidence) or confidence < threshold -> {"summary", "low_confidence"}
        is_nil(own_words) -> {"summary", "empty_text"}
        true -> {"quote", "benign"}
      end

    %{
      quote: if(used == "quote", do: own_words, else: summary(action)),
      used: used,
      reason: reason,
      label: label,
      confidence: confidence,
      benign_probability: safety && safety.benign_probability,
      threshold: threshold
    }
  end

  @doc "True when the safety read says the message asks for real-world harm, so the GM declines it in character."
  @spec decline?(safety() | nil) :: boolean()
  def decline?(%{label: :nefarious}), do: true
  def decline?(_safety), do: false

  @doc ~S"""
  A short typed summary of an action, for the GM when it does not get the
  player's own words.

      iex> alias TalesForge.Game.Schemas.{PlayerAction, SingleAction}
      iex> TalesForge.Game.PlayerQuote.summary(%PlayerAction{
      ...>   overall_intent: "x", action: %SingleAction{action_type: :speak, target: "innkeep"}})
      "speak (target: innkeep)"
      iex> TalesForge.Game.PlayerQuote.summary(%PlayerAction{
      ...>   overall_intent: "x", action: %SingleAction{action_type: :observe}})
      "observe"
  """
  @spec summary(PlayerAction.t()) :: String.t()
  def summary(%PlayerAction{action: %SingleAction{action_type: type, target: target}}) do
    case target do
      t when is_binary(t) and t != "" -> "#{type} (target: #{t})"
      _ -> to_string(type)
    end
  end

  @doc "The decision as string-keyed `ai_calls.meta` (without the quote text itself)."
  @spec meta(decision()) :: map()
  def meta(decision) do
    %{
      "used" => decision.used,
      "reason" => decision.reason,
      "label" => decision.label,
      "confidence" => decision.confidence,
      "benign_probability" => decision.benign_probability,
      "threshold" => decision.threshold
    }
  end

  defp own_words(raw_action) do
    Intent.sanitize_quote(raw_action)
  rescue
    ArgumentError -> nil
  end
end
