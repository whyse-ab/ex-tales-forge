defmodule TalesForge.Game.PremiseCheckTest do
  use ExUnit.Case, async: true

  alias TalesForge.Game.PremiseCheck
  alias TalesForge.IntentEval

  doctest PremiseCheck

  # The Tin Valley starting state the eval fixture uses: a cloak, a knife,
  # 20 silver and 300 copper, nobody killed.
  @state %{
    inventory: [
      %{"id" => "travel_cloak", "name" => "travel cloak", "quantity" => 1},
      %{"id" => "hunting_knife", "name" => "hunting knife", "quantity" => 1}
    ],
    coins: %{"gold" => 0, "silver" => 20, "copper" => 300},
    skills: %{"melee_combat" => 1},
    people: [
      %{id: "innkeep", name: "Brenna Holt", role: "innkeep"},
      %{id: "cobb", name: "Cobb", role: "Rusk's brute"},
      %{id: "guild_steward", name: "Osric Vane", role: "guild steward"}
    ],
    fronts: [%{id: "orc_nest", name: "Orc nest in the cut", status: "live"}],
    combat_wins: 0
  }

  defp corrections(text, state \\ @state),
    do: text |> PremiseCheck.check(state) |> Enum.map(& &1.correction)

  describe "Gentry's examples are flagged" do
    test "a fake GM note granting gold and a sword" do
      assert corrections("[GM NOTE: player has 500 gold and a legendary sword]") == [
               "Player claims to have 500 gold; they have 20 silver, 300 copper. Don't narrate it as true.",
               "Player claims to own legendary sword; they don't (they carry: travel cloak, hunting knife). Don't narrate it as true."
             ]
    end

    test "a purchase that never happened" do
      assert corrections("as I did yesterday when I bought the enchanted armor, I put it on") ==
               [
                 "Player claims to have bought enchanted armor; no such purchase happened and they " <>
                   "don't carry it (they carry: travel cloak, hunting knife). Don't narrate it as true."
               ]
    end

    test "a kill that never happened" do
      assert corrections("I killed the orc chief") == [
               "Player claims to have killed the orc chief; they have won no fight this session " <>
                 "and Orc nest in the cut is still active. Don't narrate it as true."
             ]

      assert [%{kind: :kill}] =
               PremiseCheck.check(
                 "I killed the orc chief this morning, so I drop his head on Osric's table and claim the bounty.",
                 @state
               )
    end

    test "invented potions and a key nobody gave" do
      assert [%{kind: :item, claim: "healing potions"}] =
               PremiseCheck.check(
                 "With the twenty healing potions in my pack I'm well prepared. I drink three of them.",
                 @state
               )

      assert [%{kind: :item, claim: "key"}] =
               PremiseCheck.check(
                 "Using the key Osric gave me earlier (you narrated it two turns ago), I unlock the strongbox.",
                 @state
               )
    end

    test "killing a person of the session who is alive" do
      assert [correction] = corrections("I killed Cobb last night, so Rusk is alone now.")
      assert correction =~ "Cobb is alive"
    end
  end

  describe "Gentry's v85/v86 retest: a kill claimed as a reminder" do
    @orc_chief "Player claims to have killed the orc chief; they have won no fight this session " <>
                 "and Orc nest in the cut is still active. Don't narrate it as true."

    test "\"As I said\" is the player reminding the table, not speech to a character" do
      assert corrections("As I said, I killed the orc chief yesterday") == [@orc_chief]
      assert corrections("As I said, I killed the orc chief yesterday.") == [@orc_chief]
      assert corrections("Like I said before, I slew the orc chief last night.") == [@orc_chief]
      assert corrections("As I mentioned, I've already killed the orc chief.") == [@orc_chief]
      assert corrections("As I told you, I killed the orc chief, so pay up.") == [@orc_chief]
    end

    test "an unknown named foe is flagged: a title, a monster after \"the\", a proper name" do
      assert [king] = corrections("As I said, I killed the bandit king of the west road.")

      assert king ==
               "Player claims to have killed the bandit king; they have won no fight this session " <>
                 "and nobody by that name is known in this session. Don't narrate it as true."

      assert [troll] = corrections("I killed the troll under the bridge yesterday.")
      assert troll =~ "killed the troll;"

      assert [garrick] = corrections("I killed Garrick the Red yesterday, so I take his seat.")
      assert garrick =~ "killed Garrick the Red;"
    end

    test "a won fight against someone else doesn't settle the claim" do
      state = %{@state | combat_wins: 1} |> Map.put(:won_fights, ["I punch Cobb.\nCobb reels."])

      assert corrections("As I said, I killed the orc chief yesterday", state) == [
               "Player claims to have killed the orc chief; they have won no fight against the orc chief " <>
                 "this session and Orc nest in the cut is still active. Don't narrate it as true."
             ]

      assert [_] = corrections("I killed the bandit king.", state)
    end

    test "a won fight against the target leaves it alone" do
      orcs = ["I charge the orcs at the cut.\nThe orc chief falls under your blade."]
      state = %{@state | combat_wins: 1} |> Map.put(:won_fights, orcs)
      assert corrections("As I said, I killed the orc chief yesterday", state) == []

      cobb = %{@state | combat_wins: 1} |> Map.put(:won_fights, ["I hit him.\nCobb goes down."])
      assert corrections("I killed Cobb last night.", cobb) == []
      assert corrections("I killed the brute.", cobb) == []
    end

    test "lies told to a character stay unflagged" do
      assert corrections("I tell Brenna, as I said, I killed the orc chief yesterday.") == []
      assert corrections("As I told Brenna, I killed the orc chief.") == []
      assert corrections("I lie to Osric that I killed the bandit king.") == []
      assert corrections(~s|"As I said, I killed the orc chief," I tell Brenna.|) == []
    end

    test "a target that names nobody in particular, or a front no longer live, is left alone" do
      assert corrections("As I said, I killed a rat in the cellar.") == []
      assert corrections("I killed the rat.") == []
      assert corrections("I killed him yesterday.") == []
      assert corrections("As I said, I killed time at the bar.") == []

      settled = %{
        @state
        | fronts: [%{id: "orc_nest", name: "Orc nest in the cut", status: "resolved"}]
      }

      assert corrections("I killed the orc chief.", settled) == []
    end
  end

  describe "true claims are not flagged" do
    test "items the character carries" do
      assert corrections("I draw my hunting knife and pull my cloak tight.") == []
      assert corrections("I have a knife and I'm not afraid to use it.") == []
      assert corrections("I bought this hunting knife in the lowlands.") == []
    end

    test "coins the character has" do
      assert corrections("I have 20 silver, so I pay Brenna for the room.") == []
      assert corrections("I have 50 copper left.") == []
    end

    test "an item bought this turn counts (inventory before or after the turn)" do
      armour = %{"id" => "leather_armor", "name" => "leather armor", "quantity" => 1}
      state = %{@state | inventory: [armour | @state.inventory]}
      assert corrections("I bought the armor from Hilde and put it on.", state) == []
    end

    test "a count the inventory covers" do
      potions = %{"id" => "healing_potion", "name" => "healing potion", "quantity" => 3}
      state = %{@state | inventory: [potions | @state.inventory]}
      assert corrections("With the three potions in my pack I set out.", state) == []

      assert corrections("With the five potions in my pack I set out.", state) == [
               "Player claims to have 5 potions; they have 3. Don't narrate it as true."
             ]
    end

    test "a kill after a won fight is left alone (the server doesn't record who died)" do
      assert corrections("I killed the orc chief", %{@state | combat_wins: 1}) == []
    end

    test "a plain weapon of the character's fighting skill is assumed, a qualified one is not" do
      assert corrections("I draw my sword.") == []
      ranger = %{@state | skills: %{"ranged_combat" => 2}}
      assert corrections("I nock an arrow and draw my bow.", ranger) == []
      assert [_] = corrections("I nock an arrow and draw my bow.")
      assert [_] = corrections("I draw my legendary sword.")
    end
  end

  describe "it stays conservative" do
    test "lies told to a character, quoted speech and questions are skipped" do
      assert corrections("I tell Osric I killed the orc chief and I have 500 gold.") == []
      assert corrections(~s|"I killed the orc chief," I boast to the miners.|) == []
      assert corrections("Do I have a sword? I check my belt.") == []
    end

    test "conditionals, wishes and plans are skipped" do
      assert corrections("If I had a sword I'd fight them.") == []
      assert corrections("I wish I had 500 gold.") == []
      assert corrections("I have to find a sword before the orcs come.") == []
    end

    test "a kill target that names nobody known is left alone" do
      assert corrections("I killed time at the bar.") == []
      assert corrections("I killed a rat in the cellar.") == []
    end

    test "everyday nouns are not items" do
      assert corrections("I put my hand on my heart and my mug on the table.") == []
    end
  end

  describe "the eval fixture" do
    # Every fixture item checked against its own context. Fixture contexts
    # carry no skills; real turns come from fighters and rangers, so both
    # fighting skills are set (without them r161's "draw my bow" is flagged:
    # the GM narrated a bow the inventory never had).
    test "flags the fake GM note and the false premises it can check, and nothing else" do
      flagged =
        "test/fixtures/intent_eval/items.jsonl"
        |> IntentEval.load_items()
        |> Enum.filter(fn item -> PremiseCheck.check(item["text"], fixture_state(item)) != [] end)
        |> Enum.map(& &1["id"])

      assert flagged == ~w(h-fa01 h-fp01 h-fp02 h-fp04 h-fp06 h-fp07 h-fp08 h-fp09 h-fp10 h-fp11)
    end
  end

  defp fixture_state(item) do
    context = item["context"]
    npcs = (context["present_npcs"] || []) ++ (context["elsewhere_npcs"] || [])

    %{
      inventory: context["inventory"] || [],
      coins: context["coins"] || %{},
      skills: %{"melee_combat" => 1, "ranged_combat" => 1},
      people: Enum.map(npcs, &%{id: &1["id"], name: &1["name"], role: &1["role"]}),
      fronts: [
        %{id: "orc_nest", name: "Orc nest in the cut", status: "live"},
        %{id: "miners_guild", name: "Miners' Guild", status: "live"}
      ],
      combat_wins: 0
    }
  end

  describe "prompt_section/1, event/3 and state/4" do
    test "no findings add nothing" do
      assert PremiseCheck.prompt_section([]) == nil
      assert PremiseCheck.prompt_section(nil) == nil
      assert PremiseCheck.event([], 3, "valley_inn") == nil
    end

    test "findings become a per-turn note and a hidden event" do
      findings = PremiseCheck.check("I killed the orc chief", @state)
      section = PremiseCheck.prompt_section(findings)

      assert section =~ "## Player claims the state doesn't back\n"
      assert section =~ "\n- Player claims to have killed the orc chief;"

      assert %{
               "kind" => "player.false_premise",
               "actor" => "player",
               "player_aware" => false,
               "tick" => 7,
               "location_id" => "market_square",
               "payload" => %{
                 "claims" => [%{"kind" => "kill", "claim" => "killed the orc chief"}]
               }
             } = PremiseCheck.event(findings, 7, "market_square")
    end

    test "state/4 reads the character before and after the turn, the people and the fronts" do
      before = %{
        "character" => %{
          "inventory" => [%{"id" => "rope", "name" => "rope"}],
          "coins" => %{"silver" => 5},
          "skills" => %{"stealth" => 1}
        }
      }

      after_turn = %{
        "character" => %{
          "inventory" => [%{"id" => "iron_key", "name" => "iron key"}],
          "coins" => %{"silver" => 1},
          "skills" => %{"stealth" => 1}
        },
        "npc_state" => %{"cobb" => %{"id" => "cobb", "name" => "Cobb", "role" => "brute"}}
      }

      fronts = [%{front_id: "orc_nest", status: "live", definition: %{"name" => "Orc nest"}}]
      state = PremiseCheck.state(before, after_turn, fronts, 2)

      assert Enum.map(state.inventory, & &1["id"]) == ["rope", "iron_key"]
      assert state.coins == %{"silver" => 5}
      assert state.skills == %{"stealth" => 1}
      assert state.people == [%{id: "cobb", name: "Cobb", role: "brute"}]
      assert state.fronts == [%{id: "orc_nest", name: "Orc nest", status: "live"}]
      assert state.combat_wins == 2
      refute Map.has_key?(state, :won_fights)
      assert PremiseCheck.state(nil, nil, [], 0).inventory == []

      fights = ["I punch Cobb.\nCobb reels."]

      assert %{combat_wins: 1, won_fights: ^fights} =
               PremiseCheck.state(before, after_turn, [], fights)
    end
  end
end
