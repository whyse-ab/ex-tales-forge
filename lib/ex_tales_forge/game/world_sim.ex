defmodule TalesForge.Game.WorldSim do
  @moduledoc """
  Pure front and people tick. No Repo, no LLM.
  Empty fronts or people is a no-op (Crossroads).

  Fronts tick first. A clock can carry `"stages"` (`[%{"at" => 3, "move" =>
  "incident"}]`): when a rule moves the clock to or past `at`, that pack move
  fires once (`TalesForge.Game.Fronts.Moves`). What a front's moves do to
  people (`move_people`, `people_memories`) is applied to them before they
  tick, and a move's `status` (e.g. `"spent"`) becomes the front's status.

  A stage can depend on where the player character is when it comes due (the
  `time.passed` event's location):

    * `"unless_player_at"`: the stage waits while the player is at one of
      these places (it fires on a later tick);
    * `"away_move"` with `"present_at"`: when the player is not at one of the
      `present_at` places, the stage fires `away_move` instead of `move`. It
      still fires once. The Tinjacks use this to take the road toll at the inn
      while the player is out, then come to the player for their share.

  Moves get the player's place, so `"@player"` in a pack move means "where
  the player is" (`TalesForge.Game.Fronts.Moves.apply_generic/3`).
  """

  alias TalesForge.Game.Fronts.Moves
  alias TalesForge.Game.Fronts.Rules

  @spec tick(%{
          required(:fronts) => [map()],
          required(:events) => [map()],
          optional(:people) => [map()]
        }) :: {:ok, map()}
  def tick(%{fronts: fronts, events: events} = input) do
    people = Map.get(input, :people, [])
    {ticked_fronts, applied_fronts} = tick_actors(fronts, events)
    {updated_fronts, pending} = take_pending(ticked_fronts)
    {updated_people, applied_people} = people |> apply_pending(pending) |> tick_actors(events)

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
        {:ok, next, moves} when is_list(moves) -> {next, acc ++ moves}
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
    moved = put_runtime(front, put_in(runtime, path, current + scaled))

    case fire_stages(moved, clock, event) do
      {next, []} -> {:ok, next}
      {next, moves} -> {:ok, next, moves}
    end
  end

  defp apply_rule(front, _rule, _event), do: {:ok, front}

  # Stages of a clock that its value has reached and that have not fired. A
  # stage with `unless_player_at` waits while the player is at one of those
  # places (the event's location), e.g. a gang does not walk off mid-fight.
  defp fire_stages(actor, clock, event) do
    value = get_in(runtime(actor), ["clocks", clock, "value"])
    stages = List.wrap(get_in(definition(actor), ["clocks", clock, "stages"]))
    player_at = if is_map(event), do: event["location_id"]

    Enum.reduce(stages, {actor, []}, fn stage, {acc, moves} ->
      key = "#{clock}:#{stage["at"]}"
      fired = List.wrap(runtime(acc)["stages_fired"])

      if stage_due?(stage, value, key, fired, player_at) do
        move = stage_move(stage, player_at)
        {:ok, state} = Moves.apply(runtime(acc), move, definition(acc), player_at: player_at)
        state = Map.put(state, "stages_fired", fired ++ [key])
        {put_runtime(acc, state), moves ++ [%{id: actor_id(acc), move: move}]}
      else
        {acc, moves}
      end
    end)
  end

  # The stage's move, or its away_move when the player is not where it happens.
  defp stage_move(%{"away_move" => away} = stage, player_at) when is_binary(away) do
    if player_at in List.wrap(stage["present_at"]), do: stage["move"], else: away
  end

  defp stage_move(stage, _player_at), do: stage["move"]

  defp stage_due?(stage, value, key, fired, player_at) do
    is_integer(value) and is_integer(stage["at"]) and value >= stage["at"] and
      key not in fired and is_binary(stage["move"]) and
      player_at not in List.wrap(stage["unless_player_at"])
  end

  # Move a front's `status` and its pending people effects out of its runtime.
  defp take_pending(fronts) do
    Enum.map_reduce(fronts, %{}, fn front, acc ->
      state = runtime(front)
      {pending, state} = Map.pop(state, "pending", %{})
      {status, state} = Map.pop(state, "status")

      front = front |> put_runtime(state) |> maybe_put_status(status)
      {front, merge_pending(acc, pending)}
    end)
  end

  defp merge_pending(acc, pending) do
    Map.merge(acc, pending, fn _key, left, right -> Map.merge(left, right) end)
  end

  defp maybe_put_status(front, nil), do: front
  defp maybe_put_status(%{status: _} = front, status), do: %{front | status: status}
  defp maybe_put_status(front, status), do: Map.put(front, "status", status)

  defp apply_pending(people, pending) when map_size(pending) == 0, do: people

  defp apply_pending(people, pending) do
    moves = Map.get(pending, "move_people", %{})
    memories = Map.get(pending, "people_memories", %{})

    Enum.map(people, fn person ->
      id = actor_id(person)

      state =
        person
        |> runtime()
        |> put_location(moves[id])
        |> add_memory(memories[id])

      put_runtime(person, state)
    end)
  end

  defp put_location(state, nil), do: state
  defp put_location(state, location_id), do: Map.put(state, "location_id", location_id)

  defp add_memory(state, nil), do: state

  defp add_memory(state, memory),
    do: Map.update(state, "memories", [memory], &(List.wrap(&1) ++ [memory]))

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
