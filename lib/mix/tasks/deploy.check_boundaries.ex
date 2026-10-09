defmodule Mix.Tasks.Deploy.CheckBoundaries do
  @moduledoc """
  Fails when game or shared code depends on admin code (tales-forge-docs
  `docs/decisions.md`, 2026-10-09, "A fast deploy lane for admin work").

      mix deploy.check_boundaries
      mix deploy.check_boundaries --lanes .github/deploy-lanes.txt

  Admin-only merges deploy to production without Gentry or the playtest batch,
  so an `[admin]` file in `.github/deploy-lanes.txt` must not be something the
  game runs. The task compiles the project, reads the file-level dependency
  graph from `mix xref graph` (compile, export and runtime references) and
  lists every edge from a non-admin file to an `[admin]` file. `[game]` files may
  never have one; other shared files only when they are on `[wiring]` (the
  router and the application mount admin modules).

  It also fails when a pattern on `[admin]` or `[game]` matches no file in the
  repo, so the list doesn't keep stale entries that a renamed file slips past.
  CI runs it in the Test job.
  """

  use Mix.Task

  alias TalesForge.DeployLanes

  @shortdoc "Checks that game and shared code never depend on admin code"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [lanes: :string])
    lanes_path = opts[:lanes] || DeployLanes.default_path()
    lanes = DeployLanes.load(lanes_path)

    Mix.Task.run("compile")
    edges = xref_edges()

    stale = stale_patterns(lanes)
    violations = DeployLanes.boundary_violations(lanes, edges)

    case {violations, stale} do
      {[], []} ->
        Mix.shell().info(
          "deploy.check_boundaries: no game or shared file depends on an [admin] file " <>
            "(#{length(edges)} dependencies checked)"
        )

      _ ->
        Mix.raise(failure_message(lanes_path, violations, stale))
    end
  end

  defp xref_edges do
    path =
      Path.join(System.tmp_dir!(), "deploy_lanes_xref_#{System.unique_integer([:positive])}.dot")

    shell = Mix.shell()

    try do
      # Quiet: xref would print how to render the graph as a PNG.
      Mix.shell(Mix.Shell.Quiet)
      Mix.Task.rerun("xref", ["graph", "--format", "dot", "--output", path])
      path |> File.read!() |> DeployLanes.parse_xref_dot()
    after
      Mix.shell(shell)
      File.rm(path)
    end
  end

  defp stale_patterns(lanes) do
    {out, 0} = System.cmd("git", ["ls-files"])
    files = String.split(out, "\n", trim: true)

    for key <- [:admin, :game, :wiring],
        source <- DeployLanes.unused_patterns(lanes, key, files) do
      "[#{key}] #{source}"
    end
  end

  @doc false
  @spec failure_message(String.t(), [map()], [String.t()]) :: String.t()
  def failure_message(lanes_path, violations, stale) do
    edges =
      for %{kind: kind, from: from, to: to} <- violations do
        "  #{from} -> #{to}  (#{kind} code depends on admin code)"
      end

    stale_lines = for line <- stale, do: "  #{line} matches no file in the repo"

    [
      "deploy.check_boundaries failed (#{lanes_path}).",
      if(edges == [],
        do: nil,
        else:
          "Admin-only merges deploy to production without Gentry or the playtest batch, so game and " <>
            "shared code must not depend on [admin] files:"
      ),
      edges,
      if(edges == [],
        do: nil,
        else:
          "Move the shared part out of the admin file into a non-admin module, or (for a router or " <>
            "supervisor that only mounts it) add the dependent file to [wiring]."
      ),
      if(stale_lines == [], do: nil, else: "Stale patterns (fix or remove them):"),
      stale_lines
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end
end
