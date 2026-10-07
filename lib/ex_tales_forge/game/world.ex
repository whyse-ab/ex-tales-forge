defmodule TalesForge.Game.World do
  @moduledoc """
  Authored world seed for Crossroads Hamlet (Phase 1/2 transition).

  Hardcoded defaults + helpers for the Crossroads world. New sessions get
  their NPCs via NPC.seed_session (from the priv/npcs files).
  """

  alias TalesForge.Game.WorldClock

  @locations %{
    "weary_pilgrim" => %{
      "id" => "weary_pilgrim",
      "name" => "The Weary Pilgrim",
      "exits" => ["crossroads_square", "pilgrim_cellar"],
      "blurb" =>
        "A low-ceilinged tavern smelling of woodsmoke and spilled ale. Chalk marks score the slate behind the bar.",
      "fixtures" => ["chalked slate", "bar counter", "hearth"],
      "ground_items" => [],
      "scene_image_url" => nil
    },
    "crossroads_square" => %{
      "id" => "crossroads_square",
      "name" => "Crossroads Square",
      "exits" => ["weary_pilgrim", "kings_road"],
      "blurb" =>
        "Mud and cobbles churned by cart wheels. Merchants hawk wares beneath a weathered signpost.",
      "fixtures" => ["signpost", "merchant stalls"],
      "ground_items" => []
    },
    "pilgrim_cellar" => %{
      "id" => "pilgrim_cellar",
      "name" => "Pilgrim Cellar",
      "exits" => ["weary_pilgrim"],
      "blurb" =>
        "Cool stone steps descend to casks and shadows. The air tastes of wine and damp mortar.",
      "fixtures" => ["wine casks", "mortar seam"],
      "ground_items" => []
    }
  }

  @npcs %{
    "marta_kellen" => %{
      "id" => "marta_kellen",
      "name" => "Marta Kellen",
      "role" => "barkeep",
      "disposition" => "wary but fair",
      "portrait_url" => nil
    }
  }

  def locations, do: @locations
  def npcs, do: @npcs

  def location(id), do: Map.get(@locations, id)

  def runtime_location(world_state, location_id) when is_map(world_state) do
    get_in(world_state, ["locations", location_id]) || location(location_id) || %{}
  end

  def scene_image_url(location_id) do
    location_id
    |> location()
    |> case do
      %{"scene_image_url" => url} when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  def default_world_state do
    %{
      "adventure_id" => "crossroads_ledger",
      "location_id" => "weary_pilgrim",
      "location_name" => "The Weary Pilgrim",
      "present_npcs" => ["marta_kellen"],
      "world_tick" => WorldClock.default_start_tick(),
      "world_clock" => WorldClock.format(WorldClock.default_start_tick()),
      "last_scene_location" => nil,
      "situation_lines" => [
        "You have just pushed through the tavern door.",
        "Marta Kellen watches from behind the bar."
      ],
      "character" => %{
        "id" => "elara_voss",
        "name" => "Elara Voss",
        "race" => "human",
        "location_id" => "weary_pilgrim",
        "stats" => %{"STR" => 12, "DEX" => 14, "CON" => 11, "INT" => 13, "WIS" => 12, "CHA" => 14},
        "skills" => %{
          "insight" => 2,
          "persuasion" => 3,
          "stealth" => 2,
          "melee_combat" => 1
        },
        "learning_points" => %{},
        "learning_failures" => %{},
        "wounds" => 0,
        "wound_max" => 3,
        "vitality" => "ok",
        "coins" => %{"gold" => 2, "silver" => 10, "copper" => 0},
        "inventory" => [
          %{"id" => "travel_cloak", "name" => "travel cloak", "quantity" => 1},
          %{"id" => "hunting_knife", "name" => "hunting knife", "quantity" => 1}
        ]
      },
      "npc_state" => @npcs,
      "locations" => @locations
    }
  end
end
