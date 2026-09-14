defmodule TalesForge.Game.MechanicsTest do
  use ExUnit.Case, async: true

  alias TalesForge.Game.Mechanics
  alias TalesForge.Game.Schemas.{HandlerResult, MechanicalResolution, PlayerAction, SingleAction}

  @character %{
    "stats" => %{"STR" => 10, "DEX" => 10, "WIS" => 12, "CHA" => 14},
    "skills" => %{
      "insight" => 2,
      "persuasion" => 3,
      "climbing" => 3,
      "melee_combat" => 1
    },
    "learning_points" => %{},
    "learning_failures" => %{}
  }

  test "wound_max is 3 plus half CON above 10, minimum 1" do
    assert Mechanics.wound_max(%{"stats" => %{"CON" => 18}}) == 7
    assert Mechanics.wound_max(%{"stats" => %{"CON" => 10}}) == 3
    assert Mechanics.wound_max(%{"stats" => %{"CON" => 11}}) == 3
    assert Mechanics.wound_max(%{"stats" => %{"CON" => 3}}) == 1
    assert Mechanics.wound_max(%{}) == 3
  end

  test "perform_and_apply awards LP and returns resolution" do
    {updated, resolution} = Mechanics.perform_and_apply(@character, "insight")

    assert resolution.skill == "insight"
    assert resolution.roll in 1..20
    assert resolution.outcome in ["success", "partial_success", "failure"]
    assert Map.get(updated["learning_points"], "insight", 0) > 0
  end

  test "injected 20 on raw below 15 is failure with LP 2 and a failure count" do
    {updated, resolution} = Mechanics.perform_and_apply(@character, "insight", 20)

    assert resolution.outcome == "failure"
    assert resolution.lp_awarded == 2.0
    assert Map.get(updated["learning_points"], "insight") == 2.0
    assert Map.get(updated["learning_failures"], "insight") == 1
  end

  test "injected 20 on raw 15+ is partial_success and still counts a failure" do
    character = put_in(@character, ["skills", "insight"], 15)
    {updated, resolution} = Mechanics.perform_and_apply(character, "insight", 20)

    assert resolution.outcome == "partial_success"
    assert resolution.lp_awarded == 2.0
    assert Map.get(updated["learning_failures"], "insight") == 1
  end

  test "injected success awards 0.5 LP and does not increment failures" do
    {updated, resolution} = Mechanics.perform_and_apply(@character, "insight", 2)

    assert resolution.outcome == "success"
    assert resolution.lp_awarded == 0.5
    assert Map.get(updated["learning_points"], "insight") == 0.5
    assert Map.get(updated["learning_failures"] || %{}, "insight", 0) == 0
  end

  test "injected partial (not 20) awards 1.0 LP and does not increment failures" do
    {updated, resolution} = Mechanics.perform_and_apply(@character, "insight", 5)

    assert resolution.outcome == "partial_success"
    assert resolution.lp_awarded == 1.0
    assert Map.get(updated["learning_points"], "insight") == 1.0
    assert Map.get(updated["learning_failures"] || %{}, "insight", 0) == 0
  end

  test "move wait inventory train skip a check even when parameters carry a skill" do
    Enum.each(["move", "wait", "inventory", "train"], fn handler ->
      {_character, result} = apply_with_skill(handler, "climbing")
      assert %MechanicalResolution{outcome: "none"} = result
      assert Mechanics.resolve_check_skill(handler, "climbing", "climbing") == nil
    end)

    {character, _result} = apply_with_skill("wait", "climbing")
    assert character["learning_points"] == %{}
    assert character["learning_failures"] == %{}
  end

  test "move handler skips skill check" do
    player_action = %PlayerAction{
      overall_intent: "go outside",
      action: %SingleAction{
        action_type: :move,
        target: "crossroads_square"
      }
    }

    handler = %HandlerResult{handler: "move", target: "crossroads_square"}

    {_character, result} = Mechanics.apply_server_mechanics(@character, player_action, handler)
    assert %MechanicalResolution{outcome: "none"} = result
  end

  test "climbing failure does not increment melee_combat LP or failures" do
    character =
      @character
      |> put_in(["learning_points", "melee_combat"], 1.5)
      |> put_in(["learning_failures", "melee_combat"], 2)

    {updated, resolution} = Mechanics.perform_and_apply(character, "climbing", 20)

    assert resolution.skill == "climbing"
    assert resolution.outcome == "failure"
    assert Map.get(updated["learning_points"], "climbing") == 2.0
    assert Map.get(updated["learning_failures"], "climbing") == 1
    assert Map.get(updated["learning_points"], "melee_combat") == 1.5
    assert Map.get(updated["learning_failures"], "melee_combat") == 2
  end

  test "attempt_improvements skips LP 4 with 3 failures" do
    character = eligible(%{"climbing" => 4}, %{"climbing" => 3})
    {updated, improvements} = Mechanics.attempt_improvements(character, %{"climbing" => 20})

    assert improvements == []
    assert updated == character
  end

  test "attempt_improvements skips LP 5 with 2 failures" do
    character = eligible(%{"climbing" => 5}, %{"climbing" => 2})
    {updated, improvements} = Mechanics.attempt_improvements(character, %{"climbing" => 20})

    assert improvements == []
    assert updated == character
  end

  test "attempt_improvements hit raises skill and clears bars" do
    character = eligible(%{"climbing" => 5}, %{"climbing" => 3})
    {updated, [entry]} = Mechanics.attempt_improvements(character, %{"climbing" => 4})

    assert entry == %{
             "skill" => "climbing",
             "roll" => 4,
             "raw_skill" => 3,
             "improved" => true
           }

    assert get_in(updated, ["skills", "climbing"]) == 4
    assert Map.get(updated["learning_points"], "climbing") == 0
    assert Map.get(updated["learning_failures"], "climbing") == 0
  end

  test "attempt_improvements miss leaves skill and sets LP 1.0" do
    character = eligible(%{"climbing" => 5}, %{"climbing" => 3})
    {updated, [entry]} = Mechanics.attempt_improvements(character, %{"climbing" => 3})

    assert entry["improved"] == false
    assert entry["roll"] == 3
    assert get_in(updated, ["skills", "climbing"]) == 3
    assert Map.get(updated["learning_points"], "climbing") == 1.0
    assert Map.get(updated["learning_failures"], "climbing") == 0
  end

  test "eligible LP 10 still only one +1 this pause" do
    character = eligible(%{"climbing" => 10}, %{"climbing" => 3})
    {updated, improvements} = Mechanics.attempt_improvements(character, %{"climbing" => 4})

    assert length(improvements) == 1
    assert hd(improvements)["improved"] == true
    assert get_in(updated, ["skills", "climbing"]) == 4
    assert Map.get(updated["learning_points"], "climbing") == 0
  end

  test "two eligible skills apply independently" do
    character =
      @character
      |> put_in(["skills", "stealth"], 2)
      |> Map.put("learning_points", %{"climbing" => 5, "stealth" => 5})
      |> Map.put("learning_failures", %{"climbing" => 3, "stealth" => 3})

    {updated, improvements} =
      Mechanics.attempt_improvements(character, %{"climbing" => 4, "stealth" => 2})

    assert Enum.map(improvements, & &1["skill"]) == ["climbing", "stealth"]
    assert get_in(updated, ["skills", "climbing"]) == 4
    assert get_in(updated, ["skills", "stealth"]) == 2
    assert Map.get(updated["learning_points"], "climbing") == 0
    assert Map.get(updated["learning_points"], "stealth") == 1.0
  end

  test "attempt_trained_skill hits when roll is greater than raw minus 5" do
    character = eligible(%{"persuasion" => 5}, %{"persuasion" => 3})
    character = put_in(character, ["skills", "persuasion"], 10)

    {updated, [entry]} =
      Mechanics.attempt_trained_skill(character, "persuasion", %{"persuasion" => 6})

    assert entry["improved"] == true
    assert entry["roll"] == 6
    assert entry["raw_skill"] == 10
    assert get_in(updated, ["skills", "persuasion"]) == 11
    assert Map.get(updated["learning_points"], "persuasion") == 0
    assert Map.get(updated["learning_failures"], "persuasion") == 0
  end

  test "attempt_trained_skill misses when roll is not greater than raw minus 5" do
    character = eligible(%{"persuasion" => 5}, %{"persuasion" => 3})
    character = put_in(character, ["skills", "persuasion"], 10)

    {updated, [entry]} =
      Mechanics.attempt_trained_skill(character, "persuasion", %{"persuasion" => 5})

    assert entry["improved"] == false
    assert entry["roll"] == 5
    assert get_in(updated, ["skills", "persuasion"]) == 10
    assert Map.get(updated["learning_points"], "persuasion") == 1.0
    assert Map.get(updated["learning_failures"], "persuasion") == 0
  end

  test "wait attempt_improvements auto-fails master raw without consuming LP" do
    character =
      eligible(%{"climbing" => 5}, %{"climbing" => 3})
      |> put_in(["skills", "climbing"], 16)

    {updated, [entry]} = Mechanics.attempt_improvements(character, %{"climbing" => 20})

    assert entry == %{
             "skill" => "climbing",
             "raw_skill" => 16,
             "improved" => false,
             "auto_fail" => true
           }

    refute Map.has_key?(entry, "roll")
    assert get_in(updated, ["skills", "climbing"]) == 16
    assert Map.get(updated["learning_points"], "climbing") == 5
    assert Map.get(updated["learning_failures"], "climbing") == 3
  end

  test "raw 0 eligible any 1d20 improves" do
    character =
      @character
      |> put_in(["skills", "climbing"], 0)
      |> Map.put("learning_points", %{"climbing" => 5})
      |> Map.put("learning_failures", %{"climbing" => 3})

    {updated, [entry]} = Mechanics.attempt_improvements(character, %{"climbing" => 1})

    assert entry["improved"] == true
    assert get_in(updated, ["skills", "climbing"]) == 1
  end

  defp eligible(lp, failures) do
    @character
    |> Map.put("learning_points", lp)
    |> Map.put("learning_failures", failures)
  end

  defp apply_with_skill(handler, skill) do
    player_action = %PlayerAction{
      overall_intent: "act",
      action: %SingleAction{
        action_type: :other,
        parameters: %{"skill" => skill}
      }
    }

    handler = %HandlerResult{handler: handler, skill: skill}
    Mechanics.apply_server_mechanics(@character, player_action, handler)
  end
end
