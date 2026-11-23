defmodule TalesForge.DeployLanes.SecurityCLI do
  @moduledoc """
  Decides the security lane (`TalesForge.DeployLanes.Security`) for the
  workflows, through `.github/scripts/security_lane.exs` (plain `elixir`).

  Two modes:

      # A pull request, after its CI run (.github/workflows/security-lane.yml):
      elixir .github/scripts/security_lane.exs pr --base <base sha> --head <head sha> \\
        --pr <pr.json> --ci success

      # A merge on main, after its playtest deploy (.github/workflows/playtest.yml):
      elixir .github/scripts/security_lane.exs main --sha <merge sha> \\
        --production <sha production runs> --pr <pr.json> --ci success

      # Bump helpers (TalesForge.DeployLanes.SecurityAudit): exit 0 when the
      # lock has any package version change (majors included); also
      # unlock-neighbors, lock-version and reaches:
      elixir .github/scripts/security_lane.exs bump <old mix.lock> <new mix.lock>

      # The JSON report out of `mix deps.audit --format json` output that may
      # also hold compile output (exit 3 when there is none):
      elixir .github/scripts/security_lane.exs extract-json audit.out

  `pr.json` is `gh pr view --json title,body,labels` (labels as `[{"name": …}]`).
  JSON is read with a small parser here, so no deps are needed.

  In `main` mode one more rule applies: everything production would get (the
  files changed since `--production`) is a lock-only bump of existing hex
  packages (majors included) or on the `[admin]` list. Added or removed
  packages, and git or other refs, wait for a founder OK.

  The lane goes to `$GITHUB_OUTPUT` (`lane=security|normal` and
  `advisories=<ids>`), the rules with their results to `$GITHUB_STEP_SUMMARY`,
  and both to stdout.
  """

  alias TalesForge.DeployLanes
  alias TalesForge.DeployLanes.Security

  defmodule Run do
    @moduledoc """
    One lane decision: the pull request (`pr.json` decoded), whether CI is
    green, the git runner and, in `main` mode, the deploy lanes.
    """
    defstruct [:pr, :git, :lanes, ci_green: false]

    @typedoc "One lane decision's inputs."
    @type t :: %__MODULE__{
            pr: map(),
            git: ([String.t()] -> {String.t(), non_neg_integer()}),
            lanes: TalesForge.DeployLanes.t() | nil,
            ci_green: boolean()
          }
  end

  @typedoc "Runs a git command (argument list) and returns `{output, exit_status}`."
  @type git :: ([String.t()] -> {String.t(), non_neg_integer()})

  @typedoc "The decision, ready to print."
  @type result :: %{lane: :security | :normal, advisories: [String.t()], summary: [String.t()]}

  @doc "Entry point for the script."
  @spec main([String.t()]) :: :ok
  def main([mode | argv]) when mode in ["pr", "main"] do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv,
        strict: [
          base: :string,
          head: :string,
          sha: :string,
          production: :string,
          pr: :string,
          ci: :string,
          lanes: :string
        ]
      )

    run = %Run{
      pr: opts[:pr] |> File.read!() |> decode_pr(),
      ci_green: opts[:ci] == "success",
      git: &git/1
    }

    emit(decide(mode, run, opts))
  end

  def main(["extract-json", path]) do
    case extract_json(File.read!(path)) do
      {:ok, json} ->
        IO.write(json)

      :error ->
        IO.puts(:stderr, "no JSON object with \"vulnerabilities\" found in #{path}")
        System.halt(3)
    end
  end

  def main(_argv) do
    IO.puts(
      :stderr,
      "usage: security_lane.exs pr|main [options] (see TalesForge.DeployLanes.SecurityCLI)"
    )

    System.halt(2)
  end

  defp decide("pr", run, opts), do: decide_pr(run, opts[:base], opts[:head])

  defp decide("main", run, opts) do
    lanes = DeployLanes.load(opts[:lanes] || DeployLanes.default_path())
    decide_main(%{run | lanes: lanes}, opts[:sha], blank_to_nil(opts[:production]))
  end

  @doc "The lane of a pull request: its changes from the merge base of `base` and `head` to `head`."
  @spec decide_pr(Run.t(), String.t(), String.t()) :: result()
  def decide_pr(%Run{git: git} = run, base, head) do
    {merge_base, _} = git.(["merge-base", base, head])
    from = String.trim(merge_base)
    result = Security.check(input(run, from, head))
    render(result, "pull request (`#{short(from)}`..`#{short(head)}`)", run.pr)
  end

  @doc """
  The lane of merge `sha` on main: the merge against its first parent, plus
  everything since the commit production runs (`nil` when unknown). The run
  needs its `lanes`.
  """
  @spec decide_main(Run.t(), String.t(), String.t() | nil) :: result()
  def decide_main(%Run{} = run, sha, production) do
    merge = Security.check(input(run, "#{sha}^1", sha))
    since = since_production(run, sha, production)
    lane = if since.ok, do: merge.lane, else: :normal
    render(%{merge | rules: merge.rules ++ [since], lane: lane}, "merge `#{short(sha)}`", run.pr)
  end

  @doc false
  @spec since_production(Run.t(), String.t(), String.t() | nil) :: Security.rule()
  def since_production(_run, _sha, nil),
    do: since_rule(false, "The commit production runs is unknown (no `deployed/production` tag).")

  def since_production(%Run{git: git} = run, sha, production) do
    cond do
      production == sha ->
        since_rule(false, "Production already runs `#{short(sha)}`.")

      elem(git.(["merge-base", "--is-ancestor", production, sha]), 1) != 0 ->
        since_rule(
          false,
          "Production runs `#{short(production)}`, which is not an ancestor of this merge."
        )

      true ->
        since_changes(run, production, sha)
    end
  end

  # Production is behind and an ancestor: what it would get on top.
  defp since_changes(%Run{git: git, lanes: lanes}, production, sha) do
    files = changed_files(git, production, sha)
    others = Enum.reject(files, &(&1 in ["mix.lock", "mix.exs"] or DeployLanes.admin?(lanes, &1)))

    cond do
      others != [] ->
        others_rule(others)

      "mix.exs" in files and not pins_only?(git, production, sha) ->
        since_rule(false, "Since production, `mix.exs` changes more than version requirements.")

      true ->
        lock_rule(lock_changes(git, production, sha), production)
    end
  end

  defp others_rule(others),
    do:
      since_rule(
        false,
        "Production would also get changes that wait for a founder OK: " <>
          Enum.map_join(Enum.take(others, 20), ", ", &"`#{&1}`") <> "."
      )

  defp lock_rule(:error, _production),
    do: since_rule(false, "Since production, `mix.lock` could not be parsed.")

  defp lock_rule(changes, production) do
    case Enum.reject(changes, &Security.existing_hex_change?/1) do
      [] ->
        since_rule(
          true,
          "Since `#{short(production)}`: only lock bumps and admin files."
        )

      bad ->
        since_rule(
          false,
          "Since production, a package was added, removed, or is not hex: " <>
            Security.describe_changes(bad)
        )
    end
  end

  defp pins_only?(git, from, to),
    do:
      Security.only_version_pins?(
        show(git, from, "mix.exs") || "",
        show(git, to, "mix.exs") || ""
      )

  defp lock_changes(git, from, to) do
    Security.lock_changes(show(git, from, "mix.lock") || "", show(git, to, "mix.lock") || "")
  rescue
    ArgumentError -> :error
  end

  defp since_rule(ok, detail), do: %{name: "Production gets nothing else", ok: ok, detail: detail}

  defp input(%Run{pr: pr, git: git} = run, from, to) do
    %{
      files: changed_files(git, from, to),
      old_lock: show(git, from, "mix.lock"),
      new_lock: show(git, to, "mix.lock"),
      old_mix_exs: show(git, from, "mix.exs"),
      new_mix_exs: show(git, to, "mix.exs"),
      title: pr["title"] || "",
      body: pr["body"] || "",
      labels: Enum.map(pr["labels"] || [], &(&1["name"] || "")),
      ci_green: run.ci_green
    }
  end

  defp render(result, what, pr) do
    advisories = Security.advisory_ids((pr["title"] || "") <> "\n" <> (pr["body"] || ""))

    heading =
      case result.lane do
        :security -> "### Security lane: yes"
        :normal -> "### Security lane: no, normal lane"
      end

    rules =
      Enum.map(result.rules, fn r ->
        "- #{if r.ok, do: "PASS", else: "FAIL"} **#{r.name}:** #{r.detail}"
      end)

    outcome =
      case result.lane do
        :security ->
          [
            "",
            "All rules pass for the #{what}: it ships through playtest, the smoke check and production without a founder OK."
          ]

        :normal ->
          [
            "",
            "The #{what} takes the normal lane: playtest, then production after a founder's Approve."
          ]
      end

    %{
      lane: result.lane,
      advisories: advisories,
      summary: [heading, "" | rules] ++ outcome
    }
  end

  defp changed_files(git, from, to) do
    case git.(["diff", "--name-only", "--no-renames", from, to]) do
      {out, 0} -> String.split(out, "\n", trim: true)
      {out, status} -> raise "git diff #{from} #{to} failed (#{status}): #{out}"
    end
  end

  defp show(git, rev, path) do
    case git.(["show", "#{rev}:#{path}"]) do
      {out, 0} -> out
      _ -> nil
    end
  end

  defp emit(%{lane: lane, advisories: advisories, summary: summary}) do
    markdown = Enum.join(summary, "\n") <> "\n"
    IO.puts(markdown)
    append_env("GITHUB_OUTPUT", "lane=#{lane}\nadvisories=#{Enum.join(advisories, " ")}\n")
    append_env("GITHUB_STEP_SUMMARY", markdown)
  end

  defp append_env(var, text) do
    case System.get_env(var) do
      nil -> :ok
      "" -> :ok
      path -> File.write!(path, text, [:append])
    end
  end

  @doc """
  Reads the `gh pr view --json title,body,labels` output. A small JSON reader
  (objects, arrays, strings, numbers, booleans, null), so the script runs
  without deps.

      iex> TalesForge.DeployLanes.SecurityCLI.decode_pr(~s({"title":"security: x","labels":[{"name":"security"}]}))
      %{"labels" => [%{"name" => "security"}], "title" => "security: x"}
  """
  @spec decode_pr(String.t()) :: map()
  def decode_pr(json) do
    case value(skip(json)) do
      {map, rest} when is_map(map) ->
        if skip(rest) == "", do: map, else: raise(ArgumentError, "trailing data after JSON")

      _ ->
        raise ArgumentError, "expected a JSON object"
    end
  end

  @doc """
  The `mix deps.audit --format json` report out of `output`: the last JSON
  object with a `"vulnerabilities"` key, as the original text. Other text
  around it (compile warnings) is skipped. `:error` when there is none.

      iex> TalesForge.DeployLanes.SecurityCLI.extract_json(~s(warning: x {y} {"pass":true,"vulnerabilities":[]}))
      {:ok, ~s({"pass":true,"vulnerabilities":[]})}
      iex> TalesForge.DeployLanes.SecurityCLI.extract_json("warning: no report")
      :error
  """
  @spec extract_json(String.t()) :: {:ok, String.t()} | :error
  def extract_json(output) do
    ~r/\{/
    |> Regex.scan(output, return: :index)
    |> Enum.map(fn [{start, _}] -> report_at(output, start) end)
    |> Enum.reject(&is_nil/1)
    |> List.last()
    |> case do
      nil -> :error
      json -> {:ok, json}
    end
  end

  defp report_at(output, start) do
    text = binary_part(output, start, byte_size(output) - start)

    case value(text) do
      {%{"vulnerabilities" => list}, rest} when is_list(list) ->
        binary_part(text, 0, byte_size(text) - byte_size(rest))

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp skip(<<c, rest::binary>>) when c in ~c" \t\r\n", do: skip(rest)
  defp skip(rest), do: rest

  defp value("{" <> rest), do: object(skip(rest), %{})
  defp value("[" <> rest), do: array(skip(rest), [])
  defp value("\"" <> rest), do: string(rest, [])
  defp value("true" <> rest), do: {true, rest}
  defp value("false" <> rest), do: {false, rest}
  defp value("null" <> rest), do: {nil, rest}

  defp value(text) do
    case Regex.run(~r/\A-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/, text) do
      [num] ->
        {parse_number(num), binary_part(text, byte_size(num), byte_size(text) - byte_size(num))}

      _ ->
        raise ArgumentError, "invalid JSON"
    end
  end

  defp parse_number(num) do
    case Integer.parse(num) do
      {int, ""} -> int
      _ -> String.to_float(num)
    end
  end

  defp object("}" <> rest, acc), do: {acc, rest}

  defp object("\"" <> text, acc) do
    {key, after_key} = string(text, [])
    ":" <> after_colon = skip(after_key)
    {val, after_value} = value(skip(after_colon))
    acc = Map.put(acc, key, val)

    case skip(after_value) do
      "," <> rest -> object(skip(rest), acc)
      "}" <> rest -> {acc, rest}
    end
  end

  defp array("]" <> rest, acc), do: {Enum.reverse(acc), rest}

  defp array(text, acc) do
    {val, rest} = value(text)

    case skip(rest) do
      "," <> rest -> array(skip(rest), [val | acc])
      "]" <> rest -> {Enum.reverse([val | acc]), rest}
    end
  end

  defp string("\"" <> rest, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp string("\\u" <> <<hex::binary-size(4), rest::binary>>, acc) do
    code = String.to_integer(hex, 16)

    {char, rest} =
      if code in 0xD800..0xDBFF do
        "\\u" <> <<low::binary-size(4), rest::binary>> = rest
        {0x10000 + (code - 0xD800) * 0x400 + (String.to_integer(low, 16) - 0xDC00), rest}
      else
        {code, rest}
      end

    string(rest, [<<char::utf8>> | acc])
  end

  defp string("\\" <> <<c, rest::binary>>, acc) do
    char =
      case c do
        ?n -> "\n"
        ?t -> "\t"
        ?r -> "\r"
        ?b -> "\b"
        ?f -> "\f"
        other -> <<other>>
      end

    string(rest, [char | acc])
  end

  defp string(<<c::utf8, rest::binary>>, acc), do: string(rest, [<<c::utf8>> | acc])

  defp git(args), do: System.cmd("git", args, stderr_to_stdout: true)

  defp short(nil), do: "unknown"
  defp short(sha), do: String.slice(sha, 0, 7)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
end
