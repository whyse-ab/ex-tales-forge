defmodule TalesForge.Game.Events do
  @moduledoc """
  Pure turn → event list. Triggers live on front and NPC definitions.

  Plain move onto a watched enter location is `player.failed_notice`
  unless the mechanical outcome is success with an unless_skill.

  A `"combat"` trigger fires when the player fights one of `target_in` (the
  action's target, or any of them present when the action names none):
  `event_on_success` or `event_on_failure` by the roll. A `"check"` trigger
  fires `event` when a check with a skill in `skill_in` on one of `target_in`
  succeeds.
  """

  alias TalesForge.Game.Mechanics

  def from_turn(
        player_action,
        handler,
        mechanical,
        world_before,
        world_after,
        fronts \\ [],
        people \\ []
      ) do
    tick = Map.get(world_after, "world_tick")
    loc_before = character_loc(world_before)
    loc_after = character_loc(world_after)
    triggers = Enum.flat_map(fronts ++ people, &actor_triggers/1)

    delta =
      Map.get(world_after, "world_tick", 0) - Map.get(world_before, "world_tick", 0)

    [
      event("time.passed", true, tick, loc_after, %{"delta_ticks" => delta}, "world")
    ]
    |> Kernel.++(travel_events(loc_before, loc_after, tick))
    |> Kernel.++(notice_events(triggers, handler, mechanical, loc_before, loc_after, tick))
    |> Kernel.++(dawdle_events(triggers, loc_after, tick, delta))
    |> Kernel.++(interact_events(triggers, player_action, loc_after, tick))
    |> Kernel.++(combat_events(triggers, player_action, mechanical, world_after, tick))
    |> Kernel.++(check_events(triggers, player_action, mechanical, world_after, tick))
  end

  defp combat_events(triggers, player_action, mechanical, world_after, tick) do
    if action_type(player_action) == :combat do
      outcome = mechanical_outcome(mechanical)

      triggers
      |> Enum.filter(&(&1["on"] == "combat" and aimed_at?(&1, player_action, world_after)))
      |> Enum.flat_map(&combat_event(&1, outcome, character_loc(world_after), tick))
    else
      []
    end
  end

  defp combat_event(trigger, outcome, location_id, tick) do
    kind =
      if outcome == "success", do: trigger["event_on_success"], else: trigger["event_on_failure"]

    if is_binary(kind),
      do: [event(kind, true, tick, location_id, %{"outcome" => outcome}, "player")],
      else: []
  end

  defp check_events(triggers, player_action, mechanical, world_after, tick) do
    skill = mechanical_skill(mechanical)

    if mechanical_outcome(mechanical) == "success" and is_binary(skill) do
      triggers
      |> Enum.filter(fn trigger ->
        trigger["on"] == "check" and skill in List.wrap(trigger["skill_in"]) and
          aimed_at?(trigger, player_action, world_after)
      end)
      |> Enum.map(
        &event(&1["event"], true, tick, character_loc(world_after), %{"skill" => skill}, "player")
      )
    else
      []
    end
  end

  # The action's target is one of the trigger's people, or the action names
  # nobody and one of them is present.
  defp aimed_at?(trigger, player_action, world_after) do
    targets = List.wrap(trigger["target_in"])
    present = List.wrap(world_after["present_npcs"])

    case action_target(player_action) do
      target when is_binary(target) -> target in targets and target in present
      _ -> Enum.any?(targets, &(&1 in present))
    end
  end

  defp travel_events(from, to, tick) when is_binary(from) and is_binary(to) and from != to do
    [event("player.travel", true, tick, to, %{"from" => from, "to" => to}, "player")]
  end

  defp travel_events(_, _, _), do: []

  defp notice_events(triggers, handler, mechanical, loc_before, loc_after, tick) do
    triggers
    |> Enum.filter(&enter_trigger?(&1, loc_before, loc_after))
    |> Enum.map(&notice_event(&1, handler, mechanical, loc_after, tick))
  end

  defp enter_trigger?(trigger, loc_before, loc_after) do
    trigger["on"] == "enter" and trigger["location_id"] == loc_after and loc_before != loc_after
  end

  def notice_event(trigger, handler, mechanical, new_location, tick) do
    skill =
      Mechanics.normalize_skill_name(handler_skill(handler)) ||
        mechanical_skill(mechanical)

    unless_skills = List.wrap(trigger["unless_skill"])
    success? = mechanical_outcome(mechanical) == "success" and skill in unless_skills

    if success? do
      event(
        trigger["event_on_notice"] || "player.noticed",
        true,
        tick,
        new_location,
        %{},
        "player"
      )
    else
      event(trigger["event"] || "player.failed_notice", false, tick, new_location, %{}, "player")
    end
  end

  defp dawdle_events(triggers, loc_after, tick, delta) do
    triggers
    |> Enum.filter(&dawdle_trigger?(&1, loc_after))
    |> Enum.map(fn _ ->
      event("player.dawdled", true, tick, loc_after, %{"delta_ticks" => delta}, "player")
    end)
  end

  defp dawdle_trigger?(trigger, loc_after) do
    trigger["on"] == "time.passed" and loc_after in List.wrap(trigger["player_in"])
  end

  defp interact_events(triggers, player_action, loc_after, tick) do
    target = action_target(player_action)

    if action_type(player_action) in [:interact, :other] do
      triggers
      |> Enum.filter(&interact_trigger?(&1, loc_after, target))
      |> Enum.map(&interact_event(&1, loc_after, tick))
    else
      []
    end
  end

  defp interact_trigger?(trigger, loc_after, target) do
    trigger["on"] == "interact" and
      is_binary(target) and
      (is_nil(trigger["location_id"]) or trigger["location_id"] == loc_after) and
      target in List.wrap(trigger["target_in"])
  end

  defp interact_event(trigger, loc_after, tick) do
    event(
      trigger["event"] || "npc.slighted",
      Map.get(trigger, "player_aware", true),
      tick,
      loc_after,
      %{},
      trigger["actor_id"] || "npc"
    )
  end

  defp actor_triggers(%{definition: defn} = actor) do
    Enum.map(List.wrap(defn["triggers"]), &Map.put(&1, "actor_id", actor_id(actor)))
  end

  defp actor_triggers(%{"definition" => defn} = actor) do
    Enum.map(List.wrap(defn["triggers"]), &Map.put(&1, "actor_id", actor_id(actor)))
  end

  defp actor_triggers(_), do: []

  defp actor_id(%{npc_id: id}) when is_binary(id), do: id
  defp actor_id(%{front_id: id}) when is_binary(id), do: id
  defp actor_id(%{"npc_id" => id}) when is_binary(id), do: id
  defp actor_id(%{"front_id" => id}) when is_binary(id), do: id
  defp actor_id(_), do: nil

  defp action_type(%{action: %{action_type: type}}), do: type
  defp action_type(_), do: nil

  defp action_target(%{action: %{target: target}}), do: target
  defp action_target(_), do: nil

  defp event(kind, player_aware, tick, location_id, payload, actor) do
    %{
      "kind" => kind,
      "actor" => actor,
      "player_aware" => player_aware,
      "tick" => tick,
      "location_id" => location_id,
      "payload" => payload
    }
  end

  defp character_loc(world) when is_map(world) do
    get_in(world, ["character", "location_id"]) || world["location_id"]
  end

  defp character_loc(_), do: nil

  defp mechanical_outcome(%{outcome: outcome}), do: outcome
  defp mechanical_outcome(%{"outcome" => outcome}), do: outcome
  defp mechanical_outcome(_), do: "none"

  defp mechanical_skill(%{skill: skill}), do: Mechanics.normalize_skill_name(skill)
  defp mechanical_skill(%{"skill" => skill}), do: Mechanics.normalize_skill_name(skill)
  defp mechanical_skill(_), do: nil

  defp handler_skill(%{skill: skill}), do: skill
  defp handler_skill(_), do: nil
end
