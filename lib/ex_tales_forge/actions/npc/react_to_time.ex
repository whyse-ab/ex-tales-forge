defmodule TalesForge.Actions.NPC.ReactToTime do
  @moduledoc false

  use Jido.Action,
    name: "npc_react_to_time",
    description: "Advance NPC concern and initiative when world time passes",
    schema: []

  alias TalesForge.Actions.NPC.{AdjustConcern, EmitInitiative}

  @impl true
  def run(_params, context) do
    delta_ticks = signal_field(context, "delta_ticks", 1)

    with {:ok, concern_state} <- AdjustConcern.run(%{delta_ticks: delta_ticks}, context),
         context = update_in(context.state, &Map.merge(&1, concern_state)),
         {:ok, emit_state} <- EmitInitiative.run(%{}, context) do
      {:ok, Map.merge(concern_state, emit_state)}
    end
  end

  defp signal_field(%{signal: signal}, key, default) do
    signal.data
    |> normalize_keys()
    |> Map.get(key, default)
  end

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
