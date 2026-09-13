defmodule TalesForge.Game.WaitTest do
  use ExUnit.Case, async: true

  alias TalesForge.Game.ActionHandler
  alias TalesForge.Game.Events
  alias TalesForge.Game.Intent
  alias TalesForge.Game.Schemas.{MechanicalResolution, PlayerAction}
  alias TalesForge.Game.WorldClock
  alias TalesForge.Game.WorldSim

  @context %{
    "exits" => ["market_square"],
    "exit_names" => %{"market_square" => "Market Square"},
    "present_npcs" => [],
    "npc_details" => %{}
  }

  test "wait handler carries parsed ticks" do
    handler = handler_for("I spend three days drinking and gambling at the inn")
    assert handler.handler == "wait"
    assert ActionHandler.tick_delta(handler) == 288
  end

  test "wait ticks coerce string and float from Tier 1 JSON" do
    string_ticks =
      PlayerAction.decode(%{
        "overall_intent" => "wait",
        "action" => %{
          "action_type" => "wait",
          "target" => nil,
          "parameters" => %{"ticks" => "288"}
        }
      })

    float_ticks =
      PlayerAction.decode(%{
        "overall_intent" => "wait",
        "action" => %{
          "action_type" => "wait",
          "target" => nil,
          "parameters" => %{"ticks" => 288.0}
        }
      })

    assert ActionHandler.tick_delta(ActionHandler.resolve(string_ticks)) == 288
    assert ActionHandler.tick_delta(ActionHandler.resolve(float_ticks)) == 288
  end

  test "time.passed and dawdle events scale with wait ticks" do
    handler = handler_for("wait three days")

    world = %{
      "location_id" => "valley_inn",
      "character" => %{"location_id" => "valley_inn"},
      "world_tick" => 36
    }

    after_world = WorldClock.advance(world, ActionHandler.tick_delta(handler))
    fronts = [guild_front()]

    events =
      Events.from_turn(
        player_action("wait three days"),
        handler,
        %MechanicalResolution{outcome: "none"},
        world,
        after_world,
        fronts
      )

    time = Enum.find(events, &(&1["kind"] == "time.passed"))
    dawdle = Enum.find(events, &(&1["kind"] == "player.dawdled"))

    assert after_world["world_tick"] == 36 + 288
    assert time["payload"]["delta_ticks"] == 288
    assert dawdle["payload"]["delta_ticks"] == 288
  end

  test "one three-day dawdle writes hiring_steel" do
    handler = handler_for("I spend three days drinking and gambling at the inn")
    delta = ActionHandler.tick_delta(handler)

    {:ok, sim} =
      WorldSim.tick(%{
        fronts: [guild_front()],
        events: [
          %{
            "kind" => "player.dawdled",
            "payload" => %{"delta_ticks" => delta}
          }
        ]
      })

    [guild] = sim.fronts
    assert get_in(guild.runtime_state, ["clocks", "clear_orcs", "value"]) == 288

    assert Enum.any?(guild.runtime_state["public_facts"], &(&1["id"] == "hiring_steel"))
  end

  test "dawdle away from town does not tick the guild" do
    handler = handler_for("I wait three days")

    world = %{
      "character" => %{"location_id" => "mine_workings"},
      "world_tick" => 36
    }

    events =
      Events.from_turn(
        player_action("I wait three days"),
        handler,
        %MechanicalResolution{outcome: "none"},
        world,
        WorldClock.advance(world, 288),
        [guild_front()]
      )

    refute Enum.any?(events, &(&1["kind"] == "player.dawdled"))
  end

  defp handler_for(raw) do
    raw
    |> player_action()
    |> ActionHandler.resolve()
  end

  defp player_action(raw) do
    {bundle, _} = Intent.resolve_bundle(raw, @context)
    Intent.validate_player_action(bundle, @context)
  end

  defp guild_front do
    %{
      front_id: "miners_guild",
      status: "live",
      definition: %{
        "id" => "miners_guild",
        "triggers" => [
          %{
            "id" => "dawdle_in_town",
            "on" => "time.passed",
            "player_in" => ["valley_inn", "market_square"],
            "event" => "player.dawdled"
          }
        ],
        "rules" => [
          %{
            "id" => "tick_clear_orcs",
            "on_event" => "player.dawdled",
            "clock" => "clear_orcs",
            "delta" => 1
          }
        ],
        "public_facts_on" => %{
          "hiring_steel" => %{
            "text" => "The Miners Guild is hiring steel in the square.",
            "visibility" => ["market_square", "valley_inn"]
          }
        }
      },
      runtime_state: %{
        "clocks" => %{
          "clear_orcs" => %{"value" => 0, "threshold" => 8, "on_threshold" => "hiring_steel"}
        },
        "resources" => %{"coin" => 40},
        "public_facts" => []
      }
    }
  end
end
