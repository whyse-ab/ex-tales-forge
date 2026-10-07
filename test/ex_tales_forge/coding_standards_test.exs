defmodule TalesForge.CodingStandardsTest do
  @moduledoc """
  Coding standards (tales-forge-docs docs/coding-standards.md): every public
  function of the backfilled modules has a `@doc` (or `@doc false` when it is
  internal). Add a module here once it is backfilled; Credo's
  `Readability.Specs` check covers the same files for `@spec` (`.credo.exs`).
  """
  use ExUnit.Case, async: true

  @documented [
    TalesForge.LLM,
    TalesForge.Game.TurnProcessor,
    TalesForge.Game.Context,
    TalesForge.Game.Prompts,
    TalesForge.Game.NpcReactions,
    TalesForge.World,
    TalesForge.World.Agent,
    TalesForge.World.Extract,
    TalesForge.World.Prices,
    TalesForge.Game.Features,
    TalesForgeWeb.TimeAgo
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
