defmodule TalesForge.TeamPace do
  @moduledoc """
  The one source of the pace numbers on the founders' pages: pull requests
  (total, merged, open, closed unmerged), pull requests per day, and the
  commits on the game's main branch (total and per day).

  Every place that shows one of these numbers (the presentation's headline
  stats and its section 5, "Pace and cost") calls `current/0` (or
  `current/2`) and reads the same map, so the numbers can't disagree.

  - **Live** (`source: :live`): counted from GitHub's full lists by the live
    PR feed (`TalesForge.PrFeed`, the snapshot's `:pace`, see
    `TalesForge.PrFeed.Pace`).
  - **Fallback** (`source: :fallback`): the bundled `data.json`
    (`TalesForge.TeamPage`, its `pace` block) when the feed has no full count:
    no token, GitHub unreachable, not polled yet, or a list cut short. The
    pages then label the numbers "as of <date>" (`label/1`).

  Live or fallback is decided for the whole map, never per number.
  """

  alias TalesForge.PrFeed
  alias TalesForge.TeamPage

  @typedoc "Where the numbers came from."
  @type source :: :live | :fallback

  @typedoc """
  The pace numbers. Day lists are string-keyed like `data.json` (`"date"`,
  `"created"`, `"merged"`, `"count"`). A number missing from `data.json` is nil
  (shown as "not measured yet").
  """
  @type t :: %{
          source: source(),
          as_of: String.t() | nil,
          fetched_at: DateTime.t() | nil,
          prs_total: non_neg_integer() | nil,
          prs_merged: non_neg_integer() | nil,
          prs_open: non_neg_integer() | nil,
          prs_closed_unmerged: non_neg_integer() | nil,
          prs_by_day: [map()],
          commits: non_neg_integer() | nil,
          commits_by_day: [map()],
          first_commit: String.t() | nil
        }

  @doc """
  The pace numbers now: live from the PR feed's latest snapshot when it has a
  full count, otherwise the bundled `data.json`.
  """
  @spec current() :: t()
  def current, do: current(PrFeed.snapshot(), TeamPage.data())

  @doc """
  The pace numbers from a feed `snapshot` (live, when it carries `:pace`) or
  else from `data` (the decoded `data.json`).

      iex> live = %{as_of: "2026-10-09", fetched_at: ~U[2026-10-09 15:00:00Z], prs_total: 108,
      ...>   prs_merged: 99, prs_open: 6, prs_closed_unmerged: 3, prs_by_day: [], commits: 270,
      ...>   commits_by_day: [], first_commit: "2026-07-02"}
      iex> data = %{"pace" => %{"as_of" => "2026-10-09", "prs_total" => 90, "prs_merged" => 82}}
      iex> TalesForge.TeamPace.current(%{status: :ok, pace: live}, data) |> Map.take([:source, :prs_merged])
      %{source: :live, prs_merged: 99}
      iex> TalesForge.TeamPace.current(%{status: :unavailable, pace: nil}, data) |> Map.take([:source, :prs_merged, :commits])
      %{source: :fallback, prs_merged: 82, commits: nil}
  """
  @spec current(map(), map()) :: t()
  def current(snapshot, data) do
    case snapshot do
      %{status: :ok, pace: %{prs_total: _} = live} -> Map.put(live, :source, :live)
      _no_full_count -> from_data(data)
    end
  end

  @doc """
  The fallback: the `pace` block of `data` (the decoded `data.json`).

      iex> TalesForge.TeamPace.from_data(%{}) |> Map.take([:source, :as_of, :prs_by_day])
      %{source: :fallback, as_of: nil, prs_by_day: []}
  """
  @spec from_data(map()) :: t()
  def from_data(data) do
    pace = TeamPage.get(data, ["pace"]) || %{}

    %{
      source: :fallback,
      as_of: text(pace["as_of"]) || text(TeamPage.get(data, ["_about", "as_of"])),
      fetched_at: nil,
      prs_total: pace["prs_total"],
      prs_merged: pace["prs_merged"],
      prs_open: pace["prs_open"],
      prs_closed_unmerged: pace["prs_closed_unmerged"],
      prs_by_day: list(pace["prs_by_day"]),
      commits: pace["commits_main_ex_tales_forge"],
      commits_by_day: list(pace["commits_by_day_main"]),
      first_commit: pace["first_commit"]
    }
  end

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  @doc """
  How the pages label where the numbers came from: "live from GitHub" or
  "as of <date>" (the date of the `data.json` count).

      iex> TalesForge.TeamPace.label(%{source: :live, as_of: "2026-10-09"})
      "live from GitHub"
      iex> TalesForge.TeamPace.label(%{source: :fallback, as_of: "2026-10-09"})
      "as of 9 Oct 2026"
  """
  @spec label(t() | map()) :: String.t()
  def label(%{source: :live}), do: "live from GitHub"
  def label(%{as_of: as_of}), do: "as of " <> TeamPage.date_label(as_of)
end
