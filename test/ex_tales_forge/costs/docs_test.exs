defmodule TalesForge.Costs.DocsTest do
  @moduledoc """
  Coding standards for the costs modules (tales-forge-docs
  docs/coding-standards.md): a `@moduledoc` and a `@doc` on every public
  function. `@spec`s are checked by Credo (`Readability.Specs`, `.credo.exs`).
  """
  use ExUnit.Case, async: true

  for module <- [
        TalesForge.Costs,
        TalesForge.Costs.Peer,
        TalesForge.Costs.PlaytestRuns,
        TalesForgeWeb.CostsPeerController
      ] do
    test "#{inspect(module)} documents the module and every public function" do
      assert {:docs_v1, _, :elixir, _, moduledoc, _, entries} = Code.fetch_docs(unquote(module))
      refute moduledoc == :none

      undocumented =
        for {{kind, name, arity}, _, _, :none, _} <- entries,
            kind in [:function, :macro],
            do: "#{name}/#{arity}"

      assert undocumented == []
    end
  end
end
