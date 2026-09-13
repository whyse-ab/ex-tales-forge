defmodule TalesForge.Game.WorldSim do
  @moduledoc """
  Pure front and people tick. No Repo, no LLM.
  Empty fronts or people is a no-op (Crossroads).
  """

  alias TalesForge.Game.Fronts.Moves
  alias TalesForge.Game.Fronts.Rules

  @spec tick(%{fronts: [map()], events: [map()]}) :: {:ok, map()}
  def tick(%{fronts: fronts, events: events} = input) do
    people = Map.get(input, :people, [])
    {updated_fronts, applied_fronts} = tick_actors(fronts, events)
    {updated_people, applied_people} = tick_actors(people, events)

    {:ok,
     %{
       fronts: updated_fronts,
       people: updated_people,
       applied: applied_fronts ++ applied_people,
       unmatched: [],
       portents_fired: [],
       status_changes: []
     }}
  end

  def accept_chronicler_move(payload, known_front_ids) when is_map(payload) do
    front_id = payload["front_id"] || payload[:front_id]

    if is_binary(front_id) and front_id in known_front_ids do
      {:ok, payload}
    else
      :drop
    end
  end

  defp tick_actors(actors, events) do
    Enum.map_reduce(actors, [], fn actor, acc ->
      if live?(actor) do
        {next, moves} = apply_rules(actor, events)
        {next, acc ++ moves}
      else
        {actor, acc}
      end
    end)
  end

  defp apply_rules(actor, events) do
    {next, applied} =
      Enum.reduce(Rules.rules(actor), {actor, []}, fn rule, acc ->
        apply_matching_events(rule, events, acc)
      end)

    {maybe_threshold(next), applied}
  end

  defp apply_matching_events(rule, events, {current, applied}) do
    Enum.reduce(Rules.matching_events(current, rule, events), {current, applied}, fn event,
                                                                                     {cur, acc} ->
      case apply_rule(cur, rule, event) do
        {:ok, next, move} -> {next, acc ++ [move]}
        {:ok, next} -> {maybe_threshold(next), acc}
        {:error, _} -> {cur, acc}
      end
    end)
  end

  defp apply_rule(actor, %{"move" => move}, _event) when is_binary(move) do
    runtime = runtime(actor)
    defn = definition(actor)

    case Moves.apply(runtime, move, defn) do
      {:ok, state} ->
        {:ok, put_runtime(actor, state), %{id: actor_id(actor), move: move}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_rule(front, %{"clock" => clock, "delta" => delta}, event) when is_binary(clock) do
    runtime = runtime(front)
    path = ["clocks", clock, "value"]
    current = get_in(runtime, path) || 0
    scaled = delta * event_delta(event)
    {:ok, put_runtime(front, put_in(runtime, path, current + scaled))}
  end

  defp apply_rule(front, _rule, _event), do: {:ok, front}

  defp event_delta(event) when is_map(event) do
    case get_in(event, ["payload", "delta_ticks"]) do
      n when is_integer(n) and n > 0 -> n
      _ -> 1
    end
  end

  defp event_delta(_), do: 1

  defp maybe_threshold(front) do
    runtime = runtime(front)
    defn = definition(front)

    Enum.reduce(runtime["clocks"] || %{}, front, fn {name, clock}, acc ->
      apply_threshold(acc, name, clock, defn)
    end)
  end

  defp apply_threshold(front, _name, clock, defn) when is_map(clock) do
    threshold = clock["threshold"]
    value = clock["value"]
    key = clock["on_threshold"]
    fact = get_in(defn, ["public_facts_on", key])
    coin = get_in(runtime(front), ["resources", "coin"]) || 0

    cond do
      not is_integer(threshold) or not is_integer(value) or value < threshold ->
        front

      not is_binary(key) or not is_map(fact) ->
        front

      coin == 0 ->
        front

      true ->
        row = %{
          "id" => key,
          "text" => fact["text"],
          "visibility" => List.wrap(fact["visibility"])
        }

        put_runtime(front, update_in(runtime(front), ["public_facts"], &append_unique(&1, row)))
    end
  end

  defp apply_threshold(front, _, _, _), do: front

  defp append_unique(nil, fact), do: [fact]

  defp append_unique(list, fact) when is_list(list) do
    if Enum.any?(list, &(&1["id"] == fact["id"])), do: list, else: list ++ [fact]
  end

  defp live?(front), do: status(front) == "live"

  defp status(%{status: status}), do: status
  defp status(%{"status" => status}), do: status
  defp status(_), do: "live"

  defp actor_id(%{front_id: id}), do: id
  defp actor_id(%{npc_id: id}), do: id
  defp actor_id(%{"front_id" => id}), do: id
  defp actor_id(%{"npc_id" => id}), do: id

  defp runtime(%{runtime_state: state}), do: state
  defp runtime(%{"runtime_state" => state}), do: state

  defp definition(%{definition: defn}), do: defn
  defp definition(%{"definition" => defn}), do: defn

  defp put_runtime(front, state) when is_map_key(front, :runtime_state) do
    %{front | runtime_state: state}
  end

  defp put_runtime(front, state) do
    Map.put(front, "runtime_state", state)
  end
end
