defmodule TalesForge.Game.Fronts.Rules do
  @moduledoc """
  Tiny predicate table for PR-3. Pack JSON documents the rules;
  this module matches `on_event` (and optional location) against events.
  """

  def match(actor, events) when is_list(events) do
    actor
    |> rules()
    |> Enum.flat_map(fn rule ->
      actor
      |> matching_events(rule, events)
      |> Enum.map(&%{rule: rule, event: &1})
    end)
  end

  def matching_events(actor, rule, events) when is_list(events) do
    Enum.filter(events, &event_matches?(rule, &1, actor))
  end

  def rules(actor) do
    actor
    |> actor_def()
    |> Map.get("rules", [])
    |> List.wrap()
  end

  defp event_matches?(rule, event, actor) do
    on = rule["on_event"]
    loc = rule["location_id"]

    on == event["kind"] and
      (is_nil(loc) or loc == event["location_id"]) and
      felt_ok?(rule["if_felt"], actor) and
      agreeableness_ok?(rule["agreeableness_lte"], actor)
  end

  defp felt_ok?(nil, _actor), do: true

  defp felt_ok?(felt, actor) when is_binary(felt) do
    actor
    |> runtime()
    |> Map.get("memories", [])
    |> List.wrap()
    |> Enum.any?(&(&1["felt"] == felt))
  end

  defp felt_ok?(_, _), do: true

  defp agreeableness_ok?(nil, _actor), do: true

  defp agreeableness_ok?(max, actor) when is_integer(max) do
    agreeableness(actor) <= max
  end

  defp agreeableness_ok?(_, _), do: true

  defp agreeableness(actor) do
    actor
    |> actor_def()
    |> get_in(["motivations", "personality_traits", "agreeableness"]) || 5
  end

  defp runtime(%{runtime_state: state}) when is_map(state), do: state
  defp runtime(%{"runtime_state" => state}) when is_map(state), do: state
  defp runtime(_), do: %{}

  defp actor_def(%{definition: defn}), do: defn
  defp actor_def(%{"definition" => defn}), do: defn
  defp actor_def(front) when is_map(front), do: front
end
