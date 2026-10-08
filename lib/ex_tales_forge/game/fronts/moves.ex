defmodule TalesForge.Game.Fronts.Moves do
  @moduledoc """
  Server-enforced legal move palette. Pure — no Repo.
  """

  require Logger

  @spec apply(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def apply(runtime_state, "raise_alert", pack_def) when is_map(runtime_state) do
    fact = get_in(pack_def, ["moves", "raise_alert", "public_fact"]) || %{}
    tick = runtime_state["since_tick"]

    memory = %{
      "who" => "player",
      "tick" => tick,
      "what" => "approached from the west road; scouts unseen",
      "felt" => "threatened"
    }

    state =
      runtime_state
      |> put_in(["clocks", "alert", "value"], "prepared")
      |> update_in(["memories"], &append_memory(&1, memory))
      |> update_in(["public_facts"], &append_unique_fact(&1, stringify_fact(fact)))

    {:ok, state}
  end

  def apply(runtime_state, "hire_extra", pack_def) when is_map(runtime_state) do
    coin = get_in(runtime_state, ["resources", "coin"]) || 0
    move = get_in(pack_def, ["moves", "hire_extra"]) || %{}
    wage = move["wage"] || 1

    if coin < wage do
      Logger.info("front=#{pack_def["id"]} move=hire_extra reason=no_coin")
      {:error, :illegal_move}
    else
      state =
        runtime_state
        |> put_in(["resources", "coin"], coin - wage)
        |> maybe_put_fact(move["public_fact"])
        |> maybe_put_memory(move["memory"])

      {:ok, state}
    end
  end

  def apply(runtime_state, "mark_debt", pack_def) when is_map(runtime_state) do
    memory = get_in(pack_def, ["moves", "mark_debt", "memory"]) || %{"felt" => "owed"}
    {:ok, maybe_put_memory(runtime_state, memory)}
  end

  def apply(_runtime_state, "unknown_front_probe", _pack_def) do
    {:error, :unknown_move}
  end

  def apply(runtime_state, move, pack_def) when is_binary(move) and is_map(runtime_state) do
    case get_in(pack_def, ["moves", move]) do
      %{} = spec -> {:ok, apply_generic(runtime_state, spec)}
      _ -> raise ArgumentError, "unknown legal move #{inspect(move)}"
    end
  end

  @doc """
  A move written out in the pack (`"moves" => %{name => spec}`), for moves
  without code of their own. Every key is optional:

  - `"retract_facts"`: ids of facts that are no longer true;
  - `"public_fact"`: a fact people can perceive where `visibility` says;
  - `"memory"`: the actor remembers something;
  - `"status"`: the front's new status (`"spent"` stops it);
  - `"move_people"`: `%{npc_id => location_id}`, applied by `WorldSim`;
  - `"people_memories"`: `%{npc_id => memory}`, applied by `WorldSim`;
  - `"clock"`: `%{name => value}` sets clocks.
  """
  @spec apply_generic(map(), map()) :: map()
  def apply_generic(runtime_state, spec) when is_map(spec) do
    runtime_state
    |> retract_facts(spec["retract_facts"])
    |> maybe_put_fact(spec["public_fact"])
    |> maybe_put_memory(spec["memory"])
    |> maybe_put_status(spec["status"])
    |> maybe_queue("move_people", spec["move_people"])
    |> maybe_queue("people_memories", spec["people_memories"])
    |> maybe_set_clocks(spec["clock"])
  end

  defp retract_facts(state, ids) when is_list(ids) do
    Map.update(state, "public_facts", [], fn facts ->
      Enum.reject(List.wrap(facts), &(&1["id"] in ids))
    end)
  end

  defp retract_facts(state, _), do: state

  defp maybe_put_status(state, status) when status in ["live", "dormant", "spent"],
    do: Map.put(state, "status", status)

  defp maybe_put_status(state, _), do: state

  # Things the front does to people: WorldSim takes them off the front's
  # runtime and applies them to the people in the same tick.
  defp maybe_queue(state, key, value) when is_map(value) and map_size(value) > 0 do
    Map.update(state, "pending", %{key => value}, fn pending ->
      Map.update(pending, key, value, &Map.merge(&1, value))
    end)
  end

  defp maybe_queue(state, _key, _value), do: state

  defp maybe_set_clocks(state, clocks) when is_map(clocks) do
    Enum.reduce(clocks, state, fn {name, value}, acc ->
      acc
      |> Map.put_new("clocks", %{})
      |> update_in(["clocks"], &Map.put_new(&1, name, %{}))
      |> put_in(["clocks", name, "value"], value)
    end)
  end

  defp maybe_set_clocks(state, _), do: state

  defp maybe_put_fact(state, %{"id" => id} = fact) when is_binary(id) do
    update_in(state, ["public_facts"], &append_unique_fact(&1, stringify_fact(fact)))
  end

  defp maybe_put_fact(state, _), do: state

  defp maybe_put_memory(state, memory) when is_map(memory) do
    entry =
      memory
      |> stringify_memory()
      |> Map.put_new("tick", state["since_tick"])

    update_in(state, ["memories"], &append_memory(&1, entry))
  end

  defp maybe_put_memory(state, _), do: state

  defp stringify_fact(fact) when is_map(fact) do
    %{
      "id" => fact["id"],
      "text" => fact["text"],
      "visibility" => List.wrap(fact["visibility"])
    }
    |> maybe_keep_harm(fact)
  end

  defp stringify_fact(_), do: %{}

  defp maybe_keep_harm(row, %{"harm" => harm}) when is_binary(harm) and harm != "" do
    Map.put(row, "harm", harm)
  end

  defp maybe_keep_harm(row, _), do: row

  defp stringify_memory(memory) when is_map(memory) do
    Map.new(memory, fn {k, v} -> {to_string(k), v} end)
  end

  defp append_memory(nil, memory), do: [memory]
  defp append_memory(list, memory) when is_list(list), do: list ++ [memory]

  defp append_unique_fact(nil, fact), do: [fact]

  defp append_unique_fact(list, fact) when is_list(list) do
    if Enum.any?(list, &(&1["id"] == fact["id"])) do
      list
    else
      list ++ [fact]
    end
  end
end
