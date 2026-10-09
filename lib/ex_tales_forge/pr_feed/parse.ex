defmodule TalesForge.PrFeed.Parse do
  @moduledoc """
  Turns GitHub REST answers into the plain data `TalesForge.PrFeed.build/2`
  uses. Pure functions; anything malformed is skipped, never raised on.

  - `pulls/1`: `GET /repos/:repo/pulls?state=all` into `t:TalesForge.PrFeed.pr/0`.
  - `ci_runs/1`: `GET /repos/:repo/actions/workflows/ci.yml/runs` into the CI
    status per head commit (the newest run of each commit wins).
  - `commit_shas/1`: `GET /repos/:repo/commits?sha=main` into shas, newest first.
  - `commits/1`: the same answer into shas with their commit time, for the
    pace counts (`TalesForge.PrFeed.Pace`).
  """

  alias TalesForge.PrFeed

  @doc """
  Pull requests from a pulls list. A closed pull request with `merged_at` is
  `:merged`. Entries without a number are skipped.

      iex> [pr] = TalesForge.PrFeed.Parse.pulls([%{"number" => 3, "title" => "Inn", "state" => "closed",
      ...>   "merged_at" => "2026-10-09T09:00:00Z", "merge_commit_sha" => "abc", "user" => %{"login" => "bobby"},
      ...>   "head" => %{"sha" => "def"}, "html_url" => "https://github.com/x/y/pull/3"}])
      iex> {pr.number, pr.state, pr.author, pr.merge_sha, pr.merged_at}
      {3, :merged, "bobby", "abc", ~U[2026-10-09 09:00:00Z]}
      iex> TalesForge.PrFeed.Parse.pulls(%{"message" => "Not Found"})
      []
  """
  @spec pulls(term()) :: [PrFeed.pr()]
  def pulls(list) when is_list(list), do: Enum.flat_map(list, &pull/1)
  def pulls(_other), do: []

  defp pull(%{"number" => number} = pr) when is_integer(number) and number > 0 do
    merged_at = time(pr["merged_at"])

    [
      %{
        number: number,
        title: text(pr["title"]) || "(no title)",
        author: pr |> nested("user", "login") |> text(),
        url: url(pr["html_url"]),
        state: state(pr["state"], merged_at),
        draft: pr["draft"] == true,
        head_sha: pr |> nested("head", "sha") |> text(),
        merge_sha: if(merged_at, do: text(pr["merge_commit_sha"])),
        created_at: time(pr["created_at"]),
        merged_at: merged_at,
        closed_at: time(pr["closed_at"]),
        updated_at: time(pr["updated_at"])
      }
    ]
  rescue
    _ -> []
  end

  defp pull(_other), do: []

  defp state("open", _merged_at), do: :open
  defp state(_closed, nil), do: :closed
  defp state(_closed, _merged_at), do: :merged

  @doc """
  CI status per head commit from a workflow-runs answer. Runs come newest
  first, so the first run of a commit is its current one.

      iex> TalesForge.PrFeed.Parse.ci_runs(%{"workflow_runs" => [
      ...>   %{"head_sha" => "a", "status" => "in_progress", "conclusion" => nil},
      ...>   %{"head_sha" => "a", "status" => "completed", "conclusion" => "failure"},
      ...>   %{"head_sha" => "b", "status" => "completed", "conclusion" => "success"},
      ...>   %{"head_sha" => "c", "status" => "completed", "conclusion" => "timed_out"},
      ...>   %{"head_sha" => "d", "status" => "completed", "conclusion" => "cancelled"}]})
      %{"a" => :running, "b" => :passed, "c" => :failed, "d" => :cancelled}
  """
  @spec ci_runs(term()) :: %{optional(String.t()) => PrFeed.ci()}
  def ci_runs(%{"workflow_runs" => runs}) when is_list(runs) do
    runs
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn
      %{"head_sha" => sha} = run, acc when is_binary(sha) -> Map.put(acc, sha, ci(run))
      _run, acc -> acc
    end)
  end

  def ci_runs(_other), do: %{}

  defp ci(%{"status" => "completed", "conclusion" => "success"}), do: :passed

  defp ci(%{"status" => "completed", "conclusion" => conclusion})
       when conclusion in ["failure", "timed_out", "startup_failure", "action_required"],
       do: :failed

  defp ci(%{"status" => "completed"}), do: :cancelled
  defp ci(_queued_or_running), do: :running

  @doc """
  Commit shas (lowercase) from a commits list, in the order given (newest first).

      iex> TalesForge.PrFeed.Parse.commit_shas([%{"sha" => "ABC"}, %{"nope" => 1}, %{"sha" => "def"}])
      ["abc", "def"]
      iex> TalesForge.PrFeed.Parse.commit_shas(nil)
      []
  """
  @spec commit_shas(term()) :: [String.t()]
  def commit_shas(list) when is_list(list) do
    for %{"sha" => sha} when is_binary(sha) <- list, do: String.downcase(sha)
  end

  def commit_shas(_other), do: []

  @doc """
  Commits (lowercase sha and the committer's time, when it landed on main)
  from a commits list, in the order given (newest first). Entries without a
  sha are skipped; a missing or bad time is nil.

      iex> TalesForge.PrFeed.Parse.commits([
      ...>   %{"sha" => "ABC", "commit" => %{"committer" => %{"date" => "2026-10-09T09:00:00Z"}}},
      ...>   %{"nope" => 1},
      ...>   %{"sha" => "def"}])
      [%{sha: "abc", at: ~U[2026-10-09 09:00:00Z]}, %{sha: "def", at: nil}]
      iex> TalesForge.PrFeed.Parse.commits(%{"message" => "Not Found"})
      []
  """
  @spec commits(term()) :: [TalesForge.PrFeed.Pace.commit()]
  def commits(list) when is_list(list) do
    for %{"sha" => sha} = commit when is_binary(sha) <- list do
      at =
        case commit["commit"] do
          %{} = inner -> inner |> nested("committer", "date") |> time()
          _ -> nil
        end

      %{sha: String.downcase(sha), at: at}
    end
  end

  def commits(_other), do: []

  defp nested(map, outer, inner) do
    case map[outer] do
      %{} = sub -> sub[inner]
      _ -> nil
    end
  end

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp text(_value), do: nil

  # Only GitHub links are rendered as links.
  defp url("https://github.com/" <> _ = url), do: url
  defp url(_other), do: nil

  defp time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp time(_value), do: nil
end
