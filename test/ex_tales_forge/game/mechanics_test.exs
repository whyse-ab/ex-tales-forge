defmodule TalesForge.Game.MechanicsTest do
  use ExUnit.Case, async: true

  alias TalesForge.Game.Mechanics

  @character %{
    "stats" => %{"WIS" => 12, "CHA" => 14},
    "skills" => %{"insight" => 2, "persuasion" => 3},
    "learning_points" => %{}
  }

  test "perform_and_apply awards LP and returns resolution" do
    {updated, resolution} = Mechanics.perform_and_apply(@character, "insight")

    assert resolution.skill == "insight"
    assert resolution.roll in 1..20
    assert resolution.outcome in ["success", "partial_success", "failure"]
    assert Map.get(updated["learning_points"], "insight", 0) > 0
  end

  test "move handler skips skill check" do
    player_action = %TalesForge.Game.Schemas.PlayerAction{
      overall_intent: "go outside",
      action: %TalesForge.Game.Schemas.SingleAction{
        action_type: :move,
        target: "crossroads_square"
      }
    }

    handler = %TalesForge.Game.Schemas.HandlerResult{handler: "move", target: "crossroads_square"}

    {_character, result} = Mechanics.apply_server_mechanics(@character, player_action, handler)
    assert %TalesForge.Game.Schemas.MechanicalResolution{outcome: "none"} = result
  end
end
