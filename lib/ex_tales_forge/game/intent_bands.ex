defmodule TalesForge.Game.IntentBands do
  @moduledoc """
  Assemble the act / clarify band opts from
  `TalesForge.Game.IntentClarification.defaults/1`, the live Config values,
  and caller overrides.
  """

  alias TalesForge.Config
  alias TalesForge.Game.IntentClarification

  @doc """
  `IntentClarification.defaults(version)` with `overrides` applied for keys
  that are present and not `nil` (including `0.0`).
  """
  @spec opts(:v1 | :v2, keyword()) :: keyword(float())
  def opts(version \\ :v1, overrides \\ []) do
    Enum.map(IntentClarification.defaults(version), fn {key, default} ->
      case Keyword.get(overrides, key) do
        nil -> {key, default}
        value -> {key, value}
      end
    end)
  end

  @doc """
  The live band opts: v2 defaults when `JEV_CLARIFY_V2` is on, otherwise
  today's Config values plus today's `runner_up`. `overrides` from the
  caller win.
  """
  @spec configured(keyword()) :: keyword(float())
  def configured(overrides \\ []) do
    version = if Config.jev_clarify_v2?(), do: :v2, else: :v1

    base =
      if version == :v2 do
        []
      else
        [
          act_min: Config.intent_act_min_confidence(),
          ask_below: Config.intent_ask_below_confidence(),
          ask_below_raw: Config.intent_ask_below_raw_confidence()
        ]
      end

    opts(version, Keyword.merge(base, overrides))
  end
end
