defmodule TalesForge.PrFeed.Deploys do
  @moduledoc """
  Is a merged pull request running on an app? Its merge commit is compared
  with the commit the app runs (`TalesForge.PrFeed.Versions`) along main's
  history (the newest commits of main, newest first, from GitHub).

  - `:deployed`: the merge commit is the running commit or older than it.
  - `:pending`: the merge commit is newer than the running commit.
  - `:unknown`: the running commit isn't known (no `GIT_SHA`, the other app
    didn't answer) or isn't among main's newest commits, or the merge commit
    isn't known.
  - `:not_merged`: used by `TalesForge.PrFeed` for open and closed pull requests.

  Main only moves forward and both apps deploy commits of main
  (`.github/workflows/playtest.yml`, `deploy-production.yml`), so "older on
  main" means "included". A merge commit older than the whole list is included
  whenever the running commit is in the list.
  """

  @typedoc "Where a pull request stands on one app."
  @type status :: :deployed | :pending | :unknown | :not_merged

  @doc """
  The status of `merge_sha` on an app running `running_sha`, given `main`
  (commit shas of main, newest first; nil when they couldn't be fetched).

      iex> main = ["c3", "c2", "c1"]
      iex> TalesForge.PrFeed.Deploys.status("c2", main, "c3")
      :deployed
      iex> TalesForge.PrFeed.Deploys.status("c2", main, "c2")
      :deployed
      iex> TalesForge.PrFeed.Deploys.status("c3", main, "c2")
      :pending
      iex> TalesForge.PrFeed.Deploys.status("c0", main, "c1")
      :deployed
      iex> TalesForge.PrFeed.Deploys.status("c2", main, nil)
      :unknown
      iex> TalesForge.PrFeed.Deploys.status("c2", main, "elsewhere")
      :unknown
      iex> TalesForge.PrFeed.Deploys.status("c2", nil, "c3")
      :unknown
  """
  @spec status(String.t() | nil, [String.t()] | nil, String.t() | nil) :: status()
  def status(merge_sha, main, running_sha)
      when is_binary(merge_sha) and is_list(main) and is_binary(running_sha) do
    case index(main, running_sha) do
      nil ->
        :unknown

      running ->
        case index(main, merge_sha) do
          nil -> :deployed
          merged when merged >= running -> :deployed
          _newer -> :pending
        end
    end
  end

  def status(_merge_sha, _main, _running_sha), do: :unknown

  # Full and abbreviated shas match each other (GIT_SHA may be either).
  defp index(main, sha) do
    sha = String.downcase(sha)
    Enum.find_index(main, &same_sha?(&1, sha))
  end

  defp same_sha?(a, b) when byte_size(a) >= 7 and byte_size(b) >= 7,
    do: String.starts_with?(a, b) or String.starts_with?(b, a)

  defp same_sha?(a, b), do: a == b
end
