defmodule TalesForge.DeployLanes.Security do
  @moduledoc """
  The **security** deploy lane (`docs/decisions.md`,
  2026-10-11, "Security-bump lane"): a dependency bump that fixes a published
  advisory ships to playtest, passes a smoke check and goes to production
  without a founder OK.

  A pull request qualifies only when all of these are true:

    1. **Lock only.** It changes `mix.lock` and, optionally, version
       requirements in the deps of `mix.exs`. No other file changes.
    2. **Advisory.** It has the label `security` or a title that starts with
       `security:`, and its title or body names an advisory id (`CVE-…`,
       `GHSA-…` or `EEF-CVE-…`).
    3. **CI is green** (the caller checks Test and Dialyzer and passes the
       answer in).

  A cross-major lock bump takes the same path as a same-major one (Fredrik,
  2026-11-23: major bumps merge and deploy to production automatically on
  green CI, with no Gentry check or Approve).

  When one check fails, the pull request takes the normal lane; `check/1`
  gives every reason.

  This module uses only Elixir's standard library, so the workflows load it
  with plain `elixir` (`.github/scripts/security_lane.exs`).

      iex> old = ~s(%{"plug": {:hex, :plug, "1.18.0", "x", [:mix], [], "hexpm", "y"}})
      iex> new = ~s(%{"plug": {:hex, :plug, "1.18.1", "x", [:mix], [], "hexpm", "y"}})
      iex> TalesForge.DeployLanes.Security.lock_changes(old, new)
      [%{package: "plug", from: "1.18.0", to: "1.18.1", same_major: true}]
  """

  @lock "mix.lock"
  @mix_exs "mix.exs"

  @advisory ~r/\b(?:EEF-CVE-\d{4}-\d+|CVE-\d{4}-\d{4,}|GHSA(?:-[23456789cfghjmpqrvwx]{4}){3})\b/i

  @typedoc "One package whose `mix.lock` entry changed (`nil` = absent on that side)."
  @type change :: %{
          package: String.t(),
          from: String.t() | nil,
          to: String.t() | nil,
          same_major: boolean()
        }

  @typedoc "One rule and its result, for the run summary."
  @type rule :: %{name: String.t(), ok: boolean(), detail: String.t()}

  @typedoc "What `check/1` needs: the files changed, both sides of `mix.lock` and `mix.exs`, and the PR."
  @type input :: %{
          files: [String.t()],
          old_lock: String.t() | nil,
          new_lock: String.t() | nil,
          old_mix_exs: String.t() | nil,
          new_mix_exs: String.t() | nil,
          title: String.t(),
          body: String.t(),
          labels: [String.t()],
          ci_green: boolean()
        }

  @typedoc "The lane and the rules behind it."
  @type result :: %{lane: :security | :normal, rules: [rule()], changes: [change()]}

  @doc "Checks every rule. The lane is `:security` only when all of them pass."
  @spec check(input()) :: result()
  def check(input) do
    changes = safe_lock_changes(input.old_lock, input.new_lock)

    rules = [
      files_rule(input),
      advisory_rule(input),
      %{
        name: "CI is green",
        ok: input.ci_green == true,
        detail:
          if(input.ci_green == true,
            do: "Test and Dialyzer passed.",
            else: "Test or Dialyzer did not pass."
          )
      }
    ]

    lane = if Enum.all?(rules, & &1.ok), do: :security, else: :normal
    %{lane: lane, rules: rules, changes: if(is_list(changes), do: changes, else: [])}
  end

  @doc "The advisory ids named in `text`, upper case, without duplicates."
  @spec advisory_ids(String.t() | nil) :: [String.t()]
  def advisory_ids(nil), do: []

  def advisory_ids(text) do
    @advisory |> Regex.scan(text) |> Enum.map(fn [id] -> String.upcase(id) end) |> Enum.uniq()
  end

  @doc """
  The packages whose entry differs between two `mix.lock` texts. Raises
  `ArgumentError` when a text is not a lock file.
  """
  @spec lock_changes(String.t(), String.t()) :: [change()]
  def lock_changes(old, new) do
    old = parse_lock(old)
    new = parse_lock(new)

    (Map.keys(old) ++ Map.keys(new))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reject(&(Map.get(old, &1) == Map.get(new, &1)))
    |> Enum.map(fn package ->
      from = Map.get(old, package)
      to = Map.get(new, package)
      %{package: package, from: from, to: to, same_major: same_major?(from, to)}
    end)
  end

  @doc """
  Parses `mix.lock` into `%{package => version}` without evaluating it. A git
  dependency gives its ref (`"git:<ref>"`).

      iex> TalesForge.DeployLanes.Security.parse_lock(~s(%{"a": {:hex, :a, "1.0.0", "h", [:mix], [], "hexpm", "o"}}))
      %{"a" => "1.0.0"}
  """
  @spec parse_lock(String.t()) :: %{String.t() => String.t()}
  def parse_lock(text) do
    case Code.string_to_quoted(text, emit_warnings: false) do
      {:ok, {:%{}, _, pairs}} -> Map.new(pairs, &lock_entry/1)
      _ -> raise ArgumentError, "not a mix.lock file"
    end
  end

  defp lock_entry({name, {:{}, _, [:hex, _app, version | _]}}) when is_binary(version),
    do: {to_string(name), version}

  defp lock_entry({name, {:{}, _, [:git, _url, ref | _]}}) when is_binary(ref),
    do: {to_string(name), "git:" <> ref}

  defp lock_entry({name, other}), do: {to_string(name), "other:" <> inspect(other)}

  @doc """
  True when `to` keeps the major version of `from` (for `0.x`, the minor too).
  An added or removed package, or a version that is not SemVer, gives false.

      iex> TalesForge.DeployLanes.Security.same_major?("1.4.2", "1.9.0")
      true
      iex> TalesForge.DeployLanes.Security.same_major?("1.4.2", "2.0.0")
      false
      iex> TalesForge.DeployLanes.Security.same_major?("0.5.1", "0.6.0")
      false
  """
  @spec same_major?(String.t() | nil, String.t() | nil) :: boolean()
  def same_major?(from, to) when is_binary(from) and is_binary(to) do
    with {:ok, a} <- Version.parse(from), {:ok, b} <- Version.parse(to) do
      a.major == b.major and (a.major > 0 or a.minor == b.minor)
    else
      _ -> false
    end
  end

  def same_major?(_from, _to), do: false

  @doc """
  True when two `mix.exs` texts differ only in the version requirements of
  deps (the string right after `{:name,`, such as `"~> 1.2"`).

      iex> TalesForge.DeployLanes.Security.only_version_pins?(~s({:plug, "~> 1.18"}), ~s({:plug, "~> 1.19"}))
      true
      iex> TalesForge.DeployLanes.Security.only_version_pins?(~s(version: "0.1.0"), ~s(version: "0.2.0"))
      false
  """
  @spec only_version_pins?(String.t(), String.t()) :: boolean()
  def only_version_pins?(old, new), do: mask_versions(old) == mask_versions(new)

  defp mask_versions(text) do
    Regex.replace(~r/(\{:\w+,\s*)"[^"\n]*"/, text, ~S(\1"<version>"))
  end

  defp files_rule(%{files: files} = input) do
    files = Enum.uniq(files)
    others = files -- [@lock, @mix_exs]

    cond do
      @lock not in files ->
        rule("Only mix.lock (and mix.exs pins) change", false, "`mix.lock` does not change.")

      others != [] ->
        rule(
          "Only mix.lock (and mix.exs pins) change",
          false,
          "Other files change: " <> Enum.map_join(others, ", ", &"`#{&1}`") <> "."
        )

      @mix_exs in files and
          not only_version_pins?(input.old_mix_exs || "", input.new_mix_exs || "") ->
        rule(
          "Only mix.lock (and mix.exs pins) change",
          false,
          "`mix.exs` changes more than version requirements."
        )

      true ->
        rule(
          "Only mix.lock (and mix.exs pins) change",
          true,
          Enum.map_join(files, ", ", &"`#{&1}`") <> "."
        )
    end
  end

  defp advisory_rule(input) do
    labelled = "security" in Enum.map(input.labels, &String.downcase/1)

    prefixed =
      input.title
      |> String.trim_leading()
      |> String.downcase()
      |> String.starts_with?("security:")

    ids = advisory_ids(input.title <> "\n" <> (input.body || ""))

    cond do
      not (labelled or prefixed) ->
        rule(
          "It references an advisory",
          false,
          "No label `security` and no title prefix `security:`."
        )

      ids == [] ->
        rule(
          "It references an advisory",
          false,
          "No advisory id (CVE, GHSA or EEF-CVE) in the title or body."
        )

      true ->
        rule("It references an advisory", true, Enum.join(ids, ", ") <> ".")
    end
  end

  @doc "The locked version of `package`, or `nil` when it is absent."
  @spec lock_version(String.t(), String.t()) :: String.t() | nil
  def lock_version(text, package), do: Map.get(parse_lock(text), package)

  @doc """
  True when the locked version of `package` is at least one of `patched`
  (SemVer, inclusive).
  """
  @spec reaches_patched?(String.t(), String.t(), [String.t()]) :: boolean()
  def reaches_patched?(text, package, patched) when is_list(patched) do
    case lock_version(text, package) do
      nil -> false
      version -> version_reaches?(version, patched)
    end
  end

  defp version_reaches?(version, patched) do
    case Version.parse(version) do
      {:ok, current} ->
        Enum.any?(patched, fn target ->
          case Version.parse(target) do
            {:ok, wanted} -> Version.compare(current, wanted) != :lt
            :error -> false
          end
        end)

      :error ->
        false
    end
  end

  @doc """
  Packages to unlock so `package` can move: `package` itself, lock entries
  that depend on it (a parent requirement may cap it), and the packages it
  depends on that are already locked (a newer `package` may need them to
  move, as phoenix 1.8.17 needed phoenix_pubsub). Optional deps are skipped.
  """
  @spec unlock_neighbors(String.t(), String.t()) :: [String.t()]
  def unlock_neighbors(text, package) do
    graph = lock_dep_graph(text)
    locked = MapSet.new(Map.keys(graph))

    children =
      graph
      |> Map.get(package, [])
      |> Enum.filter(&MapSet.member?(locked, &1))

    parents = for {name, deps} <- graph, package in deps, do: name

    Enum.sort(Enum.uniq([package | children ++ parents]))
  end

  @doc "Each hex package in a lock file and the required (non-optional) packages it depends on."
  @spec lock_dep_graph(String.t()) :: %{String.t() => [String.t()]}
  def lock_dep_graph(text) do
    case Code.string_to_quoted(text, emit_warnings: false) do
      {:ok, {:%{}, _, pairs}} -> Map.new(pairs, &lock_deps_entry/1)
      _ -> raise ArgumentError, "not a mix.lock file"
    end
  end

  defp lock_deps_entry({name, {:{}, _, [:hex, _, _, _, _, deps | _]}}) when is_list(deps),
    do: {to_string(name), Enum.flat_map(deps, &required_dep/1)}

  defp lock_deps_entry({name, _other}), do: {to_string(name), []}

  defp required_dep({:{}, _, [dep, _req, opts]}) when is_atom(dep) and is_list(opts) do
    if Keyword.get(opts, :optional, false), do: [], else: [to_string(dep)]
  end

  defp required_dep({dep, _req, opts}) when is_atom(dep) and is_list(opts) do
    if Keyword.get(opts, :optional, false), do: [], else: [to_string(dep)]
  end

  defp required_dep(_), do: []

  @doc "The packages as `name old -> new` (`added`/`removed` for one side)."
  @spec describe_changes([change()]) :: String.t()
  def describe_changes(changes) do
    Enum.map_join(changes, ", ", fn
      %{package: p, from: nil, to: to} -> "#{p} added (#{to})"
      %{package: p, from: from, to: nil} -> "#{p} removed (#{from})"
      %{package: p, from: from, to: to} -> "#{p} #{from} -> #{to}"
    end) <> "."
  end

  defp safe_lock_changes(old, new) when is_binary(old) and is_binary(new) do
    lock_changes(old, new)
  rescue
    ArgumentError -> {:error, "`mix.lock` could not be parsed."}
  end

  defp safe_lock_changes(_old, _new), do: {:error, "`mix.lock` is missing on one side."}

  defp rule(name, ok, detail), do: %{name: name, ok: ok, detail: detail}
end
