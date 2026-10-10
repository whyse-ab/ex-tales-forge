defmodule TalesForge.Board.OnProd do
  @moduledoc """
  Is a card's PR in the running prod release? The gate of Building → Done
  (tales-forge-docs `docs/design-board-states.md`). The board runs only on
  production, so the running release is this app's own commit (`GIT_SHA`, the
  same commit `/internal/version` gives). GitHub tells the PR's merge commit
  (`GET /repos/:repo/pulls/:number`) and whether it is an ancestor of the
  running commit (`GET /repos/:repo/compare/<merge>...<running>`: `ahead` or
  `identical`). The token is `GITHUB_FEED_TOKEN` (read-only).
  """

  alias TalesForge.Board.GitHubApp
  alias TalesForge.Playtest.RunMeta
  alias TalesForge.PrFeed

  @doc """
  `:ok` when PR `number`'s merge commit is in the running release, else
  `{:error, reason}` (a sentence for Bobby and the card).
  """
  @spec check(pos_integer() | nil) :: :ok | {:error, String.t()}
  def check(nil), do: {:error, "Link the PR that is on prod first."}

  def check(number) do
    with {:token, token} when is_binary(token) <- {:token, PrFeed.token()},
         {:running, running} when is_binary(running) <- {:running, RunMeta.git_sha()},
         {:ok, merge} <- merge_sha(token, number),
         {:ok, status} <- compare(token, merge, running) do
      if status in ["ahead", "identical"],
        do: :ok,
        else:
          {:error,
           "PR ##{number} (#{short(merge)}) is not in the prod release (#{short(running)}) yet."}
    else
      {:token, _} -> {:error, "The board cannot read GitHub now (no GITHUB_FEED_TOKEN)."}
      {:running, _} -> {:error, "The board cannot see the prod release (no GIT_SHA)."}
      {:error, reason} -> {:error, reason}
    end
  end

  defp merge_sha(token, number) do
    case get(token, "/repos/#{PrFeed.repo()}/pulls/#{number}") do
      {:ok, %{"merged" => true, "merge_commit_sha" => sha}} when is_binary(sha) -> {:ok, sha}
      {:ok, _} -> {:error, "PR ##{number} is not merged yet."}
      :error -> {:error, "GitHub did not answer for PR ##{number}. Try again later."}
    end
  end

  defp compare(token, merge, running) do
    case get(token, "/repos/#{PrFeed.repo()}/compare/#{merge}...#{running}") do
      {:ok, %{"status" => status}} -> {:ok, status}
      _ -> {:error, "GitHub did not compare the commits. Try again later."}
    end
  end

  defp get(token, path) do
    case Req.get(
           [
             url: "https://api.github.com" <> path,
             headers: [
               {"authorization", "Bearer " <> token},
               {"accept", "application/vnd.github+json"}
             ],
             retry: false,
             receive_timeout: 10_000
           ] ++ GitHubApp.req_options()
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      _ -> :error
    end
  end

  defp short(sha), do: String.slice(sha, 0, 7)
end
