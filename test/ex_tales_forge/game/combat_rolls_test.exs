defmodule TalesForge.Game.CombatRollsTest do
  @moduledoc """
  Fights roll (Jev baseline 2026-10-07, run 496574e3: Hawk's knife fight with
  goblins got "No skill check required" on every turn because the heuristic
  only knew six attack verbs).
  """
  use ExUnit.Case, async: true

  alias TalesForge.Game.{ActionHandler, Intent, Mechanics}
  alias TalesForge.Game.Schemas.SingleAction

  doctest TalesForge.Game.Mechanics, only: [first_combat_skill: 1]

  @context %{
    "exits" => ["market_square"],
    "exit_names" => %{"market_square" => "Market Square"},
    "present_npcs" => ["innkeep"],
    "npc_details" => %{"innkeep" => %{"name" => "Brenna Holt", "role" => "innkeep"}}
  }
  @baseline Map.put(@context, "variant", "baseline")

  defp primary(text, context \\ @context) do
    %{actions: [action]} = Intent.heuristic_intent(text, context)
    action
  end

  defp handler(text, context \\ @context) do
    player_action = Intent.validate_player_action(Intent.heuristic_intent(text, context), context)
    ActionHandler.resolve(player_action, Map.get(context, "variant", "default"))
  end

  describe "the default variant" do
    test "Hawk's goblin fight rolls (run 496574e3, turns 10 and 11)" do
      lunge =
        "I pivot toward the twig snap on my left, knife ready, and lunge low at the first goblin's spear arm to disable it before the bowman or hidden threat closes in."

      roll_under =
        "I ignore the pain in my shoulder, roll sideways under the club swing toward the wounded scout to grab his dropped spear, then use it to keep the club goblin at bay."

      for text <- [lunge, roll_under] do
        assert %SingleAction{action_type: :combat} = primary(text)
        assert %{handler: "skill_check", skill: "melee_combat"} = handler(text)
      end
    end

    test "more ways to attack are fights" do
      for text <- [
            "I slash at the brute's arm.",
            "I loose another arrow at the closest orc, then draw my knife.",
            "I hurl my knife at the orc prying the crate open.",
            "I tackle him into the table.",
            "I take down the sentry before he can shout."
          ] do
        assert %SingleAction{action_type: :combat} = primary(text), text
      end
    end

    test "the first fight verb picks the skill" do
      assert %{skill: "ranged_combat"} =
               handler("I loose another arrow at the closest orc, then draw my knife and charge.")

      assert %{skill: "unarmed_combat"} =
               handler("I punch him square in the jaw, then grab the club.")

      assert %{skill: "melee_combat"} =
               handler("I swing my hunting knife at the first orc's throat.")
    end

    test "fight words in speech or descriptions are not a fight and do not roll a fight skill" do
      greeting =
        ~s(I approach the bar and say, "Afternoon, Brenna. I'm a ranger looking for work, a fight if need be.")

      assert %SingleAction{action_type: :speak} = action = primary(greeting)
      refute Map.get(action.parameters, "skill")

      refute primary("Or I'll take my business and my orc-slaying sword elsewhere.").action_type ==
               :combat

      refute primary("I'll meet you at the cut at dawn, Caldern.").action_type == :combat

      refute Map.get(
               primary("I step inside, letting the door swing shut behind me.").parameters,
               "skill"
             )
    end

    test "Mechanics.first_combat_skill ignores texts without fight verbs" do
      assert Mechanics.first_combat_skill("I order a mug of ale") == nil
    end
  end

  describe "the baseline variant keeps the old rules" do
    test "only the six old attack verbs are fights" do
      refute primary("I lunge low at the goblin's spear arm.", @baseline).action_type == :combat
      assert primary("I attack the goblin.", @baseline).action_type == :combat
    end

    test "a fight word in a quote still counts" do
      assert primary(~s(I say, "Then we fight."), @baseline).action_type == :combat
    end
  end
end
