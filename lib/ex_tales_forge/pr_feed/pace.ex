defmodule TalesForge.PrFeed.Pace do
  @moduledoc """
  The pace numbers of the game's repo, counted from the live PR feed's full
  GitHub lists: every pull request and every commit on main.

  `build/3` is pure: the poller (`TalesForge.PrFeed.Poller`) hands it what it
  fetched and `TalesForge.PrFeed.build/2` stores the result in the snapshot's
  `:pace`. The pages read it only through `TalesForge.TeamPace.current/0`,
  which falls back to the bundled `data.json` when there is no live count.

  Days are calendar days in Europe/Stockholm. The day lists use the same
  string-keyed shape as `data.json` (`"date"`, `"created"`, `"merged"`,
  `"count"`), so the charts take either.
  """

  alias TalesForge.PrFeed

  @zone "Europe/Stockholm"

  @typedoc "A commit on main as the feed parses it: sha and when it was committed."
  @type commit :: %{sha: String.t(), at: DateTime.t() | nil}

  @typedoc "Live pace numbers."
  @type t :: %{
          as_of: String.t(),
          fetched_at: DateTime.t(),
          prs_total: non_neg_integer(),
          prs_merged: non_neg_integer(),
          prs_open: non_neg_integer(),
          prs_closed_unmerged: non_neg_integer(),
          prs_by_day: [%{required(String.t()) => String.t() | non_neg_integer()}],
          commits: non_neg_integer(),
          commits_by_day: [%{required(String.t()) => String.t() | non_neg_integer()}],
          first_commit: String.t() | nil
        }

  @doc """
  The pace numbers from every pull request and every commit on main, at `now`.

      iex> pr = fn n, state, created, merged -> %{number: n, state: state,
      ...>   created_at: created, merged_at: merged} end
      iex> pulls = [
      ...>   pr.(3, :open, ~U[2026-10-09 08:00:00Z], nil),
      ...>   pr.(2, :merged, ~U[2026-10-08 21:30:00Z], ~U[2026-10-08 22:10:00Z]),
      ...>   pr.(1, :closed, ~U[2026-10-07 10:00:00Z], nil)]
      iex> commits = [%{sha: "b", at: ~U[2026-10-08 22:10:00Z]}, %{sha: "a", at: ~U[2026-10-07 09:00:00Z]}]
      iex> pace = TalesForge.PrFeed.Pace.build(pulls, commits, ~U[2026-10-09 12:00:00Z])
      iex> {pace.prs_total, pace.prs_merged, pace.prs_open, pace.prs_closed_unmerged, pace.commits}
      {3, 1, 1, 1, 2}
      iex> pace.prs_by_day
      [%{"date" => "2026-10-07", "created" => 1, "merged" => 0},
       %{"date" => "2026-10-08", "created" => 1, "merged" => 0},
       %{"date" => "2026-10-09", "created" => 1, "merged" => 1}]
      iex> {pace.commits_by_day, pace.first_commit, pace.as_of}
      {[%{"date" => "2026-10-07", "count" => 1}, %{"date" => "2026-10-09", "count" => 1}], "2026-10-07", "2026-10-09"}
  """
  @spec build([PrFeed.pr() | map()], [commit()], DateTime.t()) :: t()
  def build(pulls, commits, %DateTime{} = now) do
    created = count_by_day(pulls, & &1.created_at)
    merged = pulls |> Enum.filter(&(&1.state == :merged)) |> count_by_day(& &1.merged_at)
    by_commit_day = count_by_day(commits, & &1.at)

    prs_by_day =
      (Map.keys(created) ++ Map.keys(merged))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(
        &%{"date" => &1, "created" => Map.get(created, &1, 0), "merged" => Map.get(merged, &1, 0)}
      )

    commit_days = by_commit_day |> Map.keys() |> Enum.sort()

    %{
      as_of: day(now),
      fetched_at: now,
      prs_total: length(pulls),
      prs_merged: Enum.count(pulls, &(&1.state == :merged)),
      prs_open: Enum.count(pulls, &(&1.state == :open)),
      prs_closed_unmerged: Enum.count(pulls, &(&1.state == :closed)),
      prs_by_day: prs_by_day,
      commits: length(commits),
      commits_by_day: Enum.map(commit_days, &%{"date" => &1, "count" => by_commit_day[&1]}),
      first_commit: List.first(commit_days)
    }
  end

  defp count_by_day(list, at) do
    Enum.reduce(list, %{}, fn entry, acc ->
      case at.(entry) do
        %DateTime{} = dt -> Map.update(acc, day(dt), 1, &(&1 + 1))
        _missing -> acc
      end
    end)
  end

  @doc """
  The Europe/Stockholm calendar day of `dt`, as an ISO date.

      iex> TalesForge.PrFeed.Pace.day(~U[2026-10-08 22:30:00Z])
      "2026-10-09"
  """
  @spec day(DateTime.t()) :: String.t()
  def day(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!(@zone, TimeZoneInfo.TimeZoneDatabase)
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end
end
