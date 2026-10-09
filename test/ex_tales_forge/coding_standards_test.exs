defmodule TalesForge.CodingStandardsTest do
  @moduledoc """
  Coding standards (tales-forge-docs docs/coding-standards.md): every public
  function of the backfilled modules has a `@doc` (or `@doc false` when it is
  internal). Add a module here once it is backfilled; Credo's
  `Readability.Specs` check covers the same files for `@spec` (`.credo.exs`).

  Admin modules (the `[admin]` list in `.github/deploy-lanes.txt`: surveys,
  costs, playtest admin, `/team`) are not listed: they get lighter gates, format
  and tests only (decision 2026-10-09 "A fast deploy lane for admin work").
  """
  use ExUnit.Case, async: true

  @documented [
    TalesForge.LLM,
    TalesForge.Collab.Links,
    TalesForge.Collab.Files,
    TalesForgeWeb.DocFilesController,
    Mix.Tasks.Docs.CheckLinks,
    TalesForge.Game.TurnProcessor,
    TalesForge.Game.Context,
    TalesForge.Game.Intent,
    TalesForge.Game.Movement,
    TalesForge.Game.Prompts,
    TalesForge.Game.NpcReactions,
    TalesForge.Game.Gestures,
    TalesForge.Game.Gestures.Forms,
    TalesForge.Game.Mechanics,
    TalesForge.Game.Progression,
    TalesForge.Game.Progression.Tiered,
    TalesForge.Game.Train,
    TalesForge.Game.PremiseCheck,
    TalesForge.World,
    TalesForge.World.Agent,
    TalesForge.World.Extract,
    TalesForge.World.Prices,
    TalesForge.Game.Features,
    TalesForgeWeb.TimeAgo,
    TalesForge.AppRole,
    TalesForge.DeployLanes,
    TalesForge.DeployLanes.CLI,
    Mix.Tasks.Deploy.CheckBoundaries
  ]

  for module <- @documented do
    test "#{inspect(module)} documents the module and every public function" do
      assert {:docs_v1, _, :elixir, _, moduledoc, _, entries} = Code.fetch_docs(unquote(module))
      refute moduledoc == :none, "#{inspect(unquote(module))} has no @moduledoc"

      undocumented =
        for {{kind, name, arity}, _, _, :none, _} <- entries,
            kind in [:function, :macro],
            do: "#{name}/#{arity}"

      assert undocumented == [],
             "#{inspect(unquote(module))}: add @doc (or @doc false) to #{Enum.join(undocumented, ", ")}"
    end
  end
end
