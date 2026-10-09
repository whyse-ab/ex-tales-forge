defmodule TalesForge.DeployLanes.CLI do
  @moduledoc """
  Picks the deploy lane of a commit on `main` for `.github/workflows/playtest.yml`
  (run through `.github/scripts/deploy_lane.exs`, plain `elixir`, no deps).

      elixir .github/scripts/deploy_lane.exs --sha <merge sha> --production <sha production runs>
      elixir .github/scripts/deploy_lane.exs --files lib/a.ex priv/team/data.json

  With `--sha`, the lane is `admin` only when both are admin-only:

    1. the merge itself: the files it changed against its first parent, and
    2. everything production would get: the files changed between the commit
       production runs (`--production`, the `deployed/production` tag) and the
       merge. Without this, an admin merge could carry an earlier game merge
       that is still waiting for Fredrik's OK to production.

  An unknown production commit, one that is not an ancestor of the merge, or a
  merge production already runs gives `normal`. The lane goes to
  `$GITHUB_OUTPUT` (`lane=admin|normal`), a Markdown summary to
  `$GITHUB_STEP_SUMMARY` when those are set, and both to stdout.

  `--files` classifies the given paths (for trying the list by hand).
  """

  alias TalesForge.DeployLanes

  @max_listed 40

  @typedoc "The lane decision with its reasons, as Markdown lines for the run summary."
  @type result :: %{lane: DeployLanes.lane(), summary: [String.t()]}

  @doc "Entry point: parses `argv`, prints the result and writes the GitHub Actions outputs."
  @spec main([String.t()]) :: :ok
  def main(argv) do
    {opts, files, _invalid} =
      OptionParser.parse(argv,
        strict: [sha: :string, production: :string, lanes: :string, files: :boolean]
      )

    lanes = DeployLanes.load(opts[:lanes] || DeployLanes.default_path())

    result =
      if opts[:sha] do
        decide(lanes, opts[:sha], blank_to_nil(opts[:production]), &git/1)
      else
        decide_files(lanes, files)
      end

    emit(result)
  end

  @doc """
  The lane of merge `sha` given the commit production runs (`nil` when unknown).
  `git` runs a git command (argument list) and returns `{output, exit_status}`.
  """
  @spec decide(DeployLanes.t(), String.t(), String.t() | nil, ([String.t()] ->
                                                                 {String.t(), non_neg_integer()})) ::
          result()
  def decide(lanes, sha, production, git) do
    merge = DeployLanes.classify(lanes, changed_files(git, ["#{sha}^1", sha]))
    merge_lines = ["**This merge** (`#{short(sha)}` against its parent): " <> describe(merge)]

    {since_lane, since_lines} = since_production(lanes, sha, production, git)
    lane = if merge.lane == :admin and since_lane == :admin, do: :admin, else: :normal

    %{lane: lane, summary: [heading(lane), "" | merge_lines ++ since_lines] ++ outcome(lane, sha)}
  end

  defp since_production(_lanes, _sha, nil, _git) do
    {:normal,
     [
       "**Production:** its commit is unknown (no `deployed/production` tag yet; the next " <>
         "\"Deploy to production\" run sets it), so this merge cannot take the admin lane."
     ]}
  end

  defp since_production(lanes, sha, production, git) do
    cond do
      production == sha ->
        {:normal, ["**Production** already runs `#{short(sha)}`."]}

      elem(git.(["merge-base", "--is-ancestor", production, sha]), 1) != 0 ->
        {:normal,
         [
           "**Production** runs `#{short(production)}`, which is not an ancestor of this merge " <>
             "(a rollback or another branch), so this merge cannot take the admin lane."
         ]}

      true ->
        since = DeployLanes.classify(lanes, changed_files(git, [production, sha]))

        {since.lane,
         ["**Since production** (`#{short(production)}`..`#{short(sha)}`): " <> describe(since)]}
    end
  end

  @doc "The lane of a plain list of changed files."
  @spec decide_files(DeployLanes.t(), [String.t()]) :: result()
  def decide_files(lanes, files) do
    result = DeployLanes.classify(lanes, files)
    %{lane: result.lane, summary: [heading(result.lane), "", "**Files:** " <> describe(result)]}
  end

  defp changed_files(git, range) do
    case git.(["diff", "--name-only", "--no-renames" | range]) do
      {out, 0} -> String.split(out, "\n", trim: true)
      {out, status} -> raise "git diff #{Enum.join(range, " ")} failed (#{status}): #{out}"
    end
  end

  defp describe(%{admin: [], other: []}), do: "no files changed."

  defp describe(%{lane: :admin, admin: admin}),
    do: "#{length(admin)} file(s), all on the admin list.\n\n" <> list(admin)

  defp describe(%{admin: admin, other: other}) do
    "#{length(other)} file(s) not on the admin list (#{length(admin)} on it).\n\n" <> list(other)
  end

  defp list(files) do
    shown = files |> Enum.take(@max_listed) |> Enum.map_join("\n", &"- `#{&1}`")
    more = length(files) - @max_listed
    if more > 0, do: shown <> "\n- … and #{more} more", else: shown
  end

  defp heading(:admin), do: "### Deploy lane: admin (fast lane)"
  defp heading(:normal), do: "### Deploy lane: normal"

  defp outcome(:admin, _sha) do
    [
      "",
      "Playtest and production deploy automatically: production goes through \"Verify commit\" " <>
        "(on main, Test and Dialyzer green) and deploys only while this is still the tip of main."
    ]
  end

  defp outcome(:normal, sha) do
    [
      "",
      "Playtest only. Production stays manual: after Gentry and the playtest batch and Fredrik's OK,",
      "",
      "    gh workflow run deploy-production.yml -f sha=#{sha}"
    ]
  end

  defp emit(%{lane: lane, summary: summary}) do
    markdown = Enum.join(summary, "\n") <> "\n"
    IO.puts(markdown)
    append_env("GITHUB_OUTPUT", "lane=#{lane}\n")
    append_env("GITHUB_STEP_SUMMARY", markdown)
  end

  defp append_env(var, text) do
    case System.get_env(var) do
      nil -> :ok
      "" -> :ok
      path -> File.write!(path, text, [:append])
    end
  end

  defp git(args), do: System.cmd("git", args, stderr_to_stdout: true)

  defp short(sha), do: String.slice(sha, 0, 7)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
end
