defmodule TalesForge.Board.Ranking do
  @moduledoc """
  How the Ideas column is ranked (tales-forge-docs `docs/design-idea-board.md`,
  kept by Fredrik on 2026-10-10): net votes with time decay,

      score = net_votes / (age_days + 2) ^ 0.8

  so a new idea with fair support rises and an old one fades unless it keeps
  getting votes. Ties go to the older idea. Case pulls an idea on its own when
  it has real support: score above 0.3 and in the top 3 (`pullable?/2`).
  """

  @exponent 0.8
  @offset_days 2
  @pull_min_score 0.3
  @pull_top 3

  @doc """
  The score of an idea with `net` votes, `age_days` old (fractional days).

      iex> TalesForge.Board.Ranking.score(3, 10) |> Float.round(2)
      0.41
      iex> TalesForge.Board.Ranking.score(2, 1) |> Float.round(2)
      0.83
      iex> TalesForge.Board.Ranking.score(2, 2) |> Float.round(2)
      0.66
      iex> TalesForge.Board.Ranking.score(0, 5)
      0.0
  """
  @spec score(integer(), number()) :: float()
  def score(net, age_days) when is_integer(net) and is_number(age_days) do
    net / :math.pow(max(age_days, 0) + @offset_days, @exponent) * 1.0
  end

  @doc "Age in fractional days from `inserted_at` to `now`."
  @spec age_days(DateTime.t(), DateTime.t()) :: float()
  def age_days(inserted_at, now), do: DateTime.diff(now, inserted_at, :second) / 86_400

  @doc """
  Sorts `{score, inserted_at, item}` triples: highest score first, older first on ties.
  """
  @spec sort([{float(), DateTime.t(), term()}]) :: [term()]
  def sort(triples) do
    triples
    |> Enum.sort(fn {s1, t1, _}, {s2, t2, _} ->
      s1 > s2 or (s1 == s2 and DateTime.compare(t1, t2) != :gt)
    end)
    |> Enum.map(&elem(&1, 2))
  end

  @doc """
  True when the idea at `position` (1-based, in the ranked Ideas column) with
  `score` is one Case may pull into Refining on its own.

      iex> TalesForge.Board.Ranking.pullable?(0.41, 1)
      true
      iex> TalesForge.Board.Ranking.pullable?(0.3, 1)
      false
      iex> TalesForge.Board.Ranking.pullable?(0.9, 4)
      false
  """
  @spec pullable?(float(), pos_integer()) :: boolean()
  def pullable?(score, position), do: score > @pull_min_score and position <= @pull_top
end
