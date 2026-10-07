defmodule Mix.Tasks.Characters.Backfill do
  @moduledoc """
  Writes or refreshes `characters` rows for every existing session from the old
  state (`world_state["character"]` and `npc_instances`). Idempotent and safe
  to re-run; see `TalesForge.Characters.backfill/0`.

      mix characters.backfill

  On a release, call it over rpc instead:

      bin/ex_tales_forge rpc 'TalesForge.Characters.backfill() |> IO.inspect()'
  """
  use Mix.Task

  @shortdoc "Backfill characters rows for existing sessions"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    result = TalesForge.Characters.backfill()
    Mix.shell().info(inspect(result, pretty: true, limit: :infinity))
    if result.failed != [], do: exit({:shutdown, 1})
  end
end
