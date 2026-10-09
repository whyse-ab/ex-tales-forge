defmodule TalesForge.DeployLanes do
  @moduledoc """
  Which deploy lane a merge to `main` takes, and the boundary between game and
  admin code (tales-forge-docs `docs/decisions.md`, 2026-10-09, "A fast deploy
  lane for admin work").

  The lists live in one file, `.github/deploy-lanes.txt`:

    * `[admin]`: survey, costs, playtest admin and `/team` files. When every
      file changed since the commit production runs is on this list, the merge
      takes the **admin** lane: playtest and production are both deployed
      automatically (`.github/workflows/playtest.yml`).
    * `[game]`: game engine code. It must never depend on an `[admin]` file.
    * `[wiring]`: shared files allowed to name `[admin]` modules (the router,
      the application). Every other shared file must not depend on them either.

  Anything not on `[admin]` (game, shared, CI, docs, unknown files) takes the
  **normal** lane: playtest only, production by hand after Fredrik's OK. A
  merge with both admin and other files is normal.

  This module uses only Elixir's standard library, so the deploy workflow can
  load it with plain `elixir` (`.github/scripts/deploy_lane.exs`), without deps
  or a compiled app.

  Patterns: `dir/` matches everything under `dir`, `*` any characters within one
  path segment, `**` any characters across segments; anything else is an exact
  path.

      iex> lanes = TalesForge.DeployLanes.parse("[admin]\\npriv/team/\\n[game]\\nlib/game/*.ex\\n")
      iex> TalesForge.DeployLanes.classify(lanes, ["priv/team/data.json"]).lane
      :admin
      iex> TalesForge.DeployLanes.classify(lanes, ["priv/team/data.json", "lib/game/turn.ex"]).lane
      :normal
  """

  @default_path ".github/deploy-lanes.txt"
  @sections %{"admin" => :admin, "game" => :game, "wiring" => :wiring}

  @typedoc "A deploy lane: `:admin` deploys playtest and production, `:normal` playtest only."
  @type lane :: :admin | :normal

  @typedoc "One pattern from the lanes file, with the regex it compiles to."
  @type pattern :: %{source: String.t(), regex: Regex.t()}

  @typedoc "The parsed lanes file."
  @type t :: %{admin: [pattern()], game: [pattern()], wiring: [pattern()]}

  @typedoc "The lane of a set of changed files, with the files split by list."
  @type classification :: %{lane: lane(), admin: [String.t()], other: [String.t()]}

  @typedoc "A file-level dependency: `from` references a module defined in `to`."
  @type edge :: {from :: String.t(), to :: String.t()}

  @doc "The lanes file, relative to the repo root."
  @spec default_path() :: String.t()
  def default_path, do: @default_path

  @doc "Reads and parses the lanes file (raises when it is missing or malformed)."
  @spec load(Path.t()) :: t()
  def load(path \\ @default_path), do: path |> File.read!() |> parse()

  @doc """
  Parses the lanes file. Raises `ArgumentError` on an unknown section, a pattern
  before the first section, or an `[admin]` list that is empty.
  """
  @spec parse(String.t()) :: t()
  def parse(text) when is_binary(text) do
    {reversed, _section} =
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({%{admin: [], game: [], wiring: []}, nil}, &parse_line/2)

    lanes = Map.new(reversed, fn {key, patterns} -> {key, Enum.reverse(patterns)} end)

    if lanes.admin == [] do
      raise ArgumentError, "deploy lanes: the [admin] list is empty"
    end

    lanes
  end

  defp parse_line({line, number}, {lanes, section}) do
    case line |> String.replace(~r/#.*$/, "") |> String.trim() do
      "" ->
        {lanes, section}

      "[" <> rest ->
        name = String.trim_trailing(rest, "]")

        case Map.fetch(@sections, name) do
          {:ok, key} -> {lanes, key}
          :error -> raise ArgumentError, "deploy lanes line #{number}: unknown section [#{name}]"
        end

      pattern when section == nil ->
        raise ArgumentError,
              "deploy lanes line #{number}: #{inspect(pattern)} is not under a [section]"

      pattern ->
        {Map.update!(lanes, section, &[compile(pattern) | &1]), section}
    end
  end

  @doc """
  Compiles one pattern.

      iex> TalesForge.DeployLanes.compile("lib/team_*.ex").regex |> Regex.match?("lib/team_art.ex")
      true
  """
  @spec compile(String.t()) :: pattern()
  def compile(source) do
    body =
      source
      |> String.split("**")
      |> Enum.map_join(".*", fn part ->
        part |> String.split("*") |> Enum.map_join("[^/]*", &Regex.escape/1)
      end)

    tail = if String.ends_with?(source, "/"), do: ".*", else: ""
    %{source: source, regex: Regex.compile!("\\A" <> body <> tail <> "\\z")}
  end

  @doc "True when `path` matches one of `patterns`."
  @spec matches?([pattern()], String.t()) :: boolean()
  def matches?(patterns, path), do: Enum.any?(patterns, &Regex.match?(&1.regex, path))

  @doc "True when `path` is on the `[admin]` list."
  @spec admin?(t(), String.t()) :: boolean()
  def admin?(lanes, path), do: matches?(lanes.admin, path)

  @doc """
  The lane for a set of changed files: `:admin` only when there is at least one
  file and every file is on the `[admin]` list; otherwise `:normal`.
  """
  @spec classify(t(), [String.t()]) :: classification()
  def classify(lanes, files) do
    files = files |> Enum.reject(&(&1 == "")) |> Enum.uniq() |> Enum.sort()
    {admin, other} = Enum.split_with(files, &admin?(lanes, &1))
    lane = if admin != [] and other == [], do: :admin, else: :normal
    %{lane: lane, admin: admin, other: other}
  end

  @doc """
  The file-level edges of `mix xref graph --format dot`, as `{from, to}` pairs.
  Lines without an arrow (files with no dependencies) are skipped.
  """
  @spec parse_xref_dot(String.t()) :: [edge()]
  def parse_xref_dot(dot) do
    ~r/^\s*"([^"]+)"\s*->\s*"([^"]+)"/m
    |> Regex.scan(dot, capture: :all_but_first)
    |> Enum.map(fn [from, to] -> {from, to} end)
    |> Enum.uniq()
  end

  @doc """
  The dependency edges that break the admin boundary: a non-admin file (game or
  shared) that depends on an `[admin]` file, unless it is on `[wiring]`. Admin
  files may depend on anything. Game violations come first.
  """
  @spec boundary_violations(t(), [edge()]) :: [
          %{kind: :game | :shared, from: String.t(), to: String.t()}
        ]
  def boundary_violations(lanes, edges) do
    edges
    |> Enum.filter(fn {from, to} ->
      admin?(lanes, to) and not admin?(lanes, from) and not matches?(lanes.wiring, from)
    end)
    |> Enum.map(fn {from, to} ->
      %{kind: if(matches?(lanes.game, from), do: :game, else: :shared), from: from, to: to}
    end)
    |> Enum.sort_by(&{&1.kind != :game, &1.from, &1.to})
  end

  @doc "The patterns of `lanes` (`:admin`, `:game` or `:wiring`) that match none of `files`."
  @spec unused_patterns(t(), :admin | :game | :wiring, [String.t()]) :: [String.t()]
  def unused_patterns(lanes, key, files) do
    for pattern <- Map.fetch!(lanes, key),
        not Enum.any?(files, &Regex.match?(pattern.regex, &1)),
        do: pattern.source
  end
end
