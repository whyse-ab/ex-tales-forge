defmodule TalesForge.Game.Perception do
  @moduledoc """
  What the table GM and scene prompts may see. Single implementation
  for Context and SceneProcessor.
  """

  alias TalesForge.Fronts
  alias TalesForge.Repo
  alias TalesForge.Schemas.{GameSession, SessionEvent}

  import Ecto.Query

  def visible_world(%GameSession{} = session) do
    world = session.world_state || %{}
    fronts = Fronts.list_all(session.id)
    events = list_event_maps(session.id)
    visible_world(world, fronts, events)
  end

  def visible_world(world_state, fronts, events) when is_map(world_state) do
    loc = world_state["location_id"]

    facts =
      fronts
      |> Enum.flat_map(&fact_list/1)
      |> Enum.filter(&visible_at?(&1, loc))

    aware =
      events
      |> Enum.map(&event_map/1)
      |> Enum.filter(& &1["player_aware"])

    %{
      "location_id" => loc,
      "public_facts" => facts,
      "player_aware_events" => aware
    }
  end

  def snapshot_public_facts(world_state, fronts) do
    loc = world_state["location_id"]

    facts =
      fronts
      |> Enum.flat_map(&fact_list/1)
      |> Enum.filter(&visible_at?(&1, loc))

    Map.put(world_state, "public_facts", facts)
  end

  def scrub_situation_lines(world, hidden_events) do
    tokens = hidden_tokens(hidden_events)

    lines =
      world
      |> Map.get("situation_lines", [])
      |> Enum.reject(&contains_token?(&1, tokens))

    Map.put(world, "situation_lines", lines)
  end

  def format_facts_section(visible) do
    facts = visible["public_facts"] || []

    if facts == [] do
      "## Perceived facts\n(none)"
    else
      lines = Enum.map_join(facts, "\n", fn fact -> "- #{fact["text"]}" end)
      "## Perceived facts\n#{lines}"
    end
  end

  defp fact_list(%{runtime_state: state}), do: List.wrap(state["public_facts"])
  defp fact_list(%{"runtime_state" => state}), do: List.wrap(state["public_facts"])
  defp fact_list(_), do: []

  defp visible_at?(fact, loc), do: loc in List.wrap(fact["visibility"])

  defp event_map(%SessionEvent{} = ev) do
    %{
      "kind" => ev.kind,
      "actor" => ev.actor,
      "player_aware" => ev.player_aware,
      "tick" => ev.tick,
      "location_id" => ev.location_id,
      "payload" => ev.payload || %{}
    }
  end

  defp event_map(map) when is_map(map), do: map

  defp list_event_maps(session_id) do
    SessionEvent
    |> where([e], e.game_session_id == ^session_id)
    |> order_by([e], e.tick)
    |> Repo.all()
  end

  defp hidden_tokens(events) do
    extra =
      events
      |> Enum.flat_map(fn ev ->
        payload = ev["payload"] || %{}
        [ev["kind"], payload["what"], payload["text"]]
      end)
      |> Enum.filter(&is_binary/1)

    scout_tokens = if extra == [], do: [], else: ["prepared", "alert", "scout"]
    Enum.uniq(scout_tokens ++ extra)
  end

  defp contains_token?(line, tokens) when is_binary(line) do
    down = String.downcase(line)
    Enum.any?(tokens, fn token -> String.contains?(down, String.downcase(to_string(token))) end)
  end

  defp contains_token?(_, _), do: false
end
