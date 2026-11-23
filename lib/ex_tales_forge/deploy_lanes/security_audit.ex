defmodule TalesForge.DeployLanes.SecurityAudit do
  @moduledoc """
  Helpers for the hourly security-audit bump
  (`.github/workflows/security-audit.yml`): which packages to unlock, whether
  a lock reached a patched version, and whether two locks differ.

  Standard library only, so `.github/scripts/security_lane.exs` can load it
  with plain `elixir`.
  """

  alias TalesForge.DeployLanes.Security

  @doc "The locked version of `package`, or `nil` when it is absent."
  @spec lock_version(String.t(), String.t()) :: String.t() | nil
  def lock_version(text, package), do: Map.get(Security.parse_lock(text), package)

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

  @doc """
  Whether `new` has a version change of an existing hex package relative to
  `old` (majors included). Added or removed packages, and git or other refs,
  are an error, same as the security lane.
  """
  @spec bump(String.t(), String.t()) :: {:ok | :error, String.t()}
  def bump(old, new) do
    changes = Security.lock_changes(old, new)
    desc = if changes == [], do: "no change", else: Security.describe_changes(changes)
    ok? = changes != [] and Enum.all?(changes, &Security.existing_hex_change?/1)
    {if(ok?, do: :ok, else: :error), desc}
  end

  @doc "Entry point for the bump, unlock-neighbors, lock-version and reaches commands."
  @spec main([String.t()]) :: :ok
  def main(["bump", old, new]) do
    {status, desc} = bump(File.read!(old), File.read!(new))
    IO.puts(desc)
    if status == :ok, do: :ok, else: System.halt(1)
  end

  def main(["unlock-neighbors", lock, package]) do
    lock
    |> File.read!()
    |> unlock_neighbors(package)
    |> Enum.join(" ")
    |> IO.puts()
  end

  def main(["lock-version", lock, package]) do
    case lock_version(File.read!(lock), package) do
      nil ->
        IO.puts(:stderr, "#{package} is not in #{lock}")
        System.halt(1)

      version ->
        IO.puts(version)
    end
  end

  def main(["reaches", lock, package | patched]) do
    if reaches_patched?(File.read!(lock), package, patched) do
      :ok
    else
      System.halt(1)
    end
  end

  def main(_argv) do
    IO.puts(
      :stderr,
      "usage: security_lane.exs bump|unlock-neighbors|lock-version|reaches (see TalesForge.DeployLanes.SecurityAudit)"
    )

    System.halt(2)
  end

  defp version_reaches?(version, patched) do
    case Version.parse(version) do
      {:ok, current} -> Enum.any?(patched, &at_least?(current, &1))
      :error -> false
    end
  end

  defp at_least?(current, target) do
    case Version.parse(target) do
      {:ok, wanted} -> Version.compare(current, wanted) != :lt
      :error -> false
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
end
