defmodule TalesForge.Playtest.PlayerView do
  @moduledoc """
  The persona bot's turn prompt, built only from what the play page shows: the
  transcript, header, NPC panel, character panel and clarification card. Never
  session events, GM reasoning or roll details.
  """

  alias TalesForge.GameSessions
  alias TalesForge.Repo
  alias TalesForgeWeb.PlayComponents

  @transcript_entries 12

  def render(session_id, clarification, turn, turn_limit) do
    session = session_id |> GameSessions.get_session!() |> Repo.preload([:turns, :scenes])
    world = session.world_state || %{}
    character = Map.get(world, "character", %{})

    [
      "Turn #{turn} of #{turn_limit}.",
      "Where: #{Map.get(world, "location_name", "Unknown")} · Time: #{Map.get(world, "world_clock", "—")}",
      "Character: #{Map.get(character, "name", "—")} · #{PlayComponents.quick_stats(character)}",
      "Inventory: #{inventory(character)}",
      "Here: #{npcs(world)}",
      "Story so far (latest last):\n" <> transcript(session),
      question(clarification)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

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

  defp transcript(session) do
    session
    |> GameSessions.transcript()
    |> Enum.take(-@transcript_entries)
    |> Enum.map_join("\n\n", &"[#{label(&1.role)}] #{&1.text}")
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
