defmodule TalesForge.Playtest.JevHeadline do
  @moduledoc """
  The headline Jev score for playtest pages (tales-forge-docs `docs/decisions.md`,
  2026-10-08, "the headline Jev score is a confidence-weighted average").

  Jev rates every turn on the persona's 1–5 scale and returns a confidence
  (0–1). The headline is the **confidence-weighted average** of the turn scores,
  `sum(score × confidence) / sum(confidence)`, on the 1–5 scale. The
  **confident share** shows next to it: the share of turns with a confidence
  of 0.7 or more. Below the headline, the turns go into four groups:
  confident-high (score ≥ 3.5), confident-low (score ≤ 2.5),
  confident-middle, and low-confidence (confidence below 0.7).

  A turn with no confidence goes into the low-confidence group and has zero
  weight. A turn with no score is left out. When the total weight is zero, the
  headline is `nil`.

  The field names `unsure_share`, `unsure` and `unsure_below/0` stay until the
  rename PR (tales-forge-docs decisions.md, 2026-10-10, positive framing). The
  text that this module makes uses the confidence form.
  """

  @unsure_below 0.7
  @high_from 3.5
  @low_up_to 2.5

  @typedoc "One scored turn: a `PlaytestScore` row or any map with these keys."
  @type row :: %{required(:overall) => number() | nil, required(:confidence) => number() | nil}

  @typedoc "The headline and the breakdown underneath it."
  @type t :: %{
          score: float() | nil,
          unsure_share: float() | nil,
          turns: non_neg_integer(),
          high: non_neg_integer(),
          low: non_neg_integer(),
          middle: non_neg_integer(),
          unsure: non_neg_integer()
        }

  @doc "The confidence that a turn must have to be confident (0.7). A lower confidence puts the turn in the low-confidence group."
  @spec unsure_below() :: float()
  def unsure_below, do: @unsure_below

  @doc """
  Headline and breakdown for a list of scored turns.

      iex> TalesForge.Playtest.JevHeadline.summarize([
      ...>   %{overall: 4.0, confidence: 0.75},
      ...>   %{overall: 2.0, confidence: 0.25}
      ...> ])
      %{score: 3.5, unsure_share: 0.5, turns: 2, high: 1, low: 0, middle: 0, unsure: 1}

      iex> TalesForge.Playtest.JevHeadline.summarize([])
      %{score: nil, unsure_share: nil, turns: 0, high: 0, low: 0, middle: 0, unsure: 0}
  """
  @spec summarize([row()]) :: t()
  def summarize(rows) when is_list(rows) do
    scored = Enum.filter(rows, &is_number(&1.overall))
    weight = scored |> Enum.map(&weight/1) |> Enum.sum()
    turns = length(scored)
    groups = Enum.frequencies_by(scored, &group/1)

    %{
      score: if(weight > 0, do: weighted(scored, weight)),
      unsure_share: if(turns > 0, do: Map.get(groups, :unsure, 0) / turns),
      turns: turns,
      high: Map.get(groups, :high, 0),
      low: Map.get(groups, :low, 0),
      middle: Map.get(groups, :middle, 0),
      unsure: Map.get(groups, :unsure, 0)
    }
  end

  @doc """
  The headline as one line, for example `"4.21/5 · confident 70%"`. The
  percentage is the share of turns with a confidence of 0.7 or more.

      iex> TalesForge.Playtest.JevHeadline.format(%{score: 4.214, unsure_share: 0.3})
      "4.21/5 · confident 70%"

      iex> TalesForge.Playtest.JevHeadline.format(%{score: nil, unsure_share: 1.0})
      "— · confident 0%"
  """
  @spec format(%{score: float() | nil, unsure_share: float() | nil}) :: String.t()
  def format(%{score: score, unsure_share: share}) do
    score_text = if score, do: "#{:erlang.float_to_binary(score / 1, decimals: 2)}/5", else: "—"
    share_text = if share, do: " · confident #{round((1 - share) * 100)}%", else: ""
    score_text <> share_text
  end

  @doc """
  The breakdown under the headline, for example
  `"6 high · 0 low · 1 middle · 3 low-confidence"`.

      iex> TalesForge.Playtest.JevHeadline.breakdown(%{high: 6, low: 0, middle: 1, unsure: 3})
      "6 high · 0 low · 1 middle · 3 low-confidence"
  """
  @spec breakdown(%{high: integer(), low: integer(), middle: integer(), unsure: integer()}) ::
          String.t()
  def breakdown(%{high: high, low: low, middle: middle, unsure: unsure}),
    do: "#{high} high · #{low} low · #{middle} middle · #{unsure} low-confidence"

  defp weight(%{confidence: c}) when is_number(c) and c > 0, do: c
  defp weight(_row), do: 0

  defp weighted(scored, weight) do
    total = scored |> Enum.map(&(&1.overall * weight(&1))) |> Enum.sum()
    total / weight
  end

  defp group(%{confidence: c}) when not is_number(c), do: :unsure
  defp group(%{confidence: c}) when c < @unsure_below, do: :unsure
  defp group(%{overall: s}) when s >= @high_from, do: :high
  defp group(%{overall: s}) when s <= @low_up_to, do: :low
  defp group(_row), do: :middle
end
