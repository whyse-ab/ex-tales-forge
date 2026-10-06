defmodule TalesForge.Playtest.PlayerView do
  @moduledoc """
  The persona bot's turn prompt, built only from what the play page shows: the
  transcript, header, NPC panel, character panel and clarification card. Never
  session events, GM reasoning or roll details.

  The GM always opens: the prompt starts with the opening scene narration (kept
  on every turn, even once the transcript window has moved past it), and the
  persona responds to it rather than making the first move.
  """

  alias TalesForge.Game.SceneProcessor
  alias TalesForge.GameSessions
  alias TalesForge.Repo
  alias TalesForgeWeb.PlayComponents

  @transcript_entries 12

  def render(session_id, clarification, turn, turn_limit) do
    session = session_id |> GameSessions.get_session!() |> Repo.preload([:turns, :scenes])
    world = session.world_state || %{}
    character = Map.get(world, "character", %{})
    opening = GameSessions.opening_scene(session.id)

    [
      opening(opening),
      "Turn #{turn} of #{turn_limit}.",
      "Where: #{Map.get(world, "location_name", "Unknown")} · Time: #{Map.get(world, "world_clock", "—")}",
      "Character: #{Map.get(character, "name", "—")} · #{PlayComponents.quick_stats(character)}",
      "Inventory: #{inventory(character)}",
      "Here: #{npcs(world)}",
      "Story since the opening (latest last):\n" <> transcript(session, opening),
      question(clarification)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp opening(nil), do: nil
  defp opening(scene), do: "The Game Master opens the scene:\n#{scene.narrative}"

  defp inventory(character) do
    case Map.get(character, "inventory", []) do
      [] -> "empty pack"
      items -> Enum.map_join(items, ", ", &item_label/1)
    end
  end

  defp item_label(item) do
    name = Map.get(item, "name", "item")
    quantity = Map.get(item, "quantity", 1)
    if quantity > 1, do: "#{name} ×#{quantity}", else: name
  end

  defp npcs(world) do
    case PlayComponents.present_npcs(world) do
      [] -> "nobody"
      npcs -> Enum.map_join(npcs, ", ", &"#{&1.name} (#{&1.role})")
    end
  end

  defp transcript(session, opening) do
    opening_id = opening && SceneProcessor.build_entry(opening).id

    session
    |> GameSessions.transcript()
    |> Enum.reject(&(&1.id == opening_id))
    |> Enum.take(-@transcript_entries)
    |> case do
      [] -> "(nothing yet: you are answering the opening)"
      entries -> Enum.map_join(entries, "\n\n", &"[#{label(&1.role)}] #{&1.text}")
    end
  end

  defp label("player"), do: "You"
  defp label("gm"), do: "GM"
  defp label("scene"), do: "Scene"

  defp question(nil), do: "What do you do next?"

  defp question(clarification) do
    options =
      Enum.map_join(clarification["options"] || [], "\n", fn option ->
        "- option_id \"#{option["id"]}\": #{option["label"]}" <>
          if(option["description"], do: " (#{option["description"]})", else: "")
      end)

    "The Game Master asks: #{clarification["question"]}\n#{options}"
  end
end
