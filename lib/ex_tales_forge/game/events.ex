defmodule TalesForge.Game.Events do
  @moduledoc """
  Pure turn → event list. Triggers live on front definitions.

  Plain move onto a watched enter location is `player.failed_notice`
  unless the mechanical outcome is success with an unless_skill.
  """

  alias TalesForge.Game.ActionHandler
  alias TalesForge.Game.Mechanics

  def from_turn(_player_action, handler, mechanical, world_before, world_after, fronts \\ []) do
    tick = Map.get(world_after, "world_tick")
    loc_before = character_loc(world_before)
    loc_after = character_loc(world_after)
    triggers = Enum.flat_map(fronts, &front_triggers/1)
    delta = ActionHandler.tick_delta(handler)

    [
      event("time.passed", true, tick, loc_after, %{"delta_ticks" => delta}, "world")
    ]
    |> Kernel.++(travel_events(loc_before, loc_after, tick))
    |> Kernel.++(notice_events(triggers, handler, mechanical, loc_before, loc_after, tick))
    |> Kernel.++(dawdle_events(triggers, loc_after, tick, delta))
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

  defp front_triggers(%{definition: defn} = front) do
    Enum.map(List.wrap(defn["triggers"]), &Map.put(&1, "front_id", front.front_id))
  end

  defp front_triggers(front) when is_map(front) do
    defn = front[:definition] || front["definition"] || %{}
    front_id = front[:front_id] || front["front_id"]
    Enum.map(List.wrap(defn["triggers"]), &Map.put(&1, "front_id", front_id))
  end

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
