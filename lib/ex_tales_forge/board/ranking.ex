defmodule TalesForge.Board.Ranking do
  @moduledoc """
  How the Ideas column is ranked (tales-forge-docs `docs/design-idea-board.md`,
  kept by Fredrik on 2026-10-10): net votes with time decay,

      score = net_votes / (age_days + 2) ^ 0.8

  The card shows this score. The backlog order is net votes, then total
  votes (tales-forge-docs `docs/design-board-states.md`, 2026-10-10; see
  `TalesForge.Board.board/1`). Votes do not move cards and do not wake bots.
  """

  @exponent 0.8
  @offset_days 2

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
end
