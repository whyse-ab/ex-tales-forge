defmodule TalesForge.CharacterCreationTest do
  use ExUnit.Case, async: true

  alias TalesForge.CharacterCreation, as: CC
  alias TalesForge.CharacterCreation.Draft
  alias TalesForge.Characters.{Defaults, Levers}
  alias TalesForge.Game.{Mechanics, Pack}

  @adventure "tin_valley"

  defp draft(opts \\ []), do: CC.new(@adventure, Keyword.put_new(opts, :seed_key, "seed-1"))

  defp ok!({:ok, value}), do: value

  defp named(d, name \\ "Wren Ashdown"), do: d |> CC.set_name(name) |> ok!()

  describe "options/1" do
    test "every base race and class is offered with a description, Human and none first" do
      opts = CC.options(@adventure)
      labels = Defaults.rules(@adventure)

      assert hd(opts.races).id == "human"
      assert hd(opts.classes).id == "none"

      assert Enum.map(opts.races, & &1.id) |> Enum.sort() ==
               Map.keys(labels["races"]) |> Enum.sort()

      assert Enum.map(opts.classes, & &1.id) |> Enum.sort() ==
               Map.keys(labels["classes"]) |> Enum.sort()

      assert Enum.all?(opts.races ++ opts.classes, &(&1.description != ""))
      assert opts.point_buy == %{"budget" => 75, "min" => 3, "max" => 18}
    end

    test "race choices and class skill points are shown" do
      opts = CC.options(@adventure)
      human = Enum.find(opts.races, &(&1.id == "human"))
      elf = Enum.find(opts.races, &(&1.id == "elf"))
      warrior = Enum.find(opts.classes, &(&1.id == "warrior"))

      assert human.choice["count"] == 2
      assert elf.choice["from"] == ["INT", "WIS"]
      assert Enum.find(opts.races, &(&1.id == "dwarf")).choice == nil
      assert warrior.skills == %{"melee_combat" => 3, "tactics" => 2}
    end
  end

  describe "a new draft" do
    test "is Human with no class, 12s across (72 of 75 points) and two suggested picks" do
      d = draft()

      assert %Draft{race: "human", class: "none", name: ""} = d
      assert d.base_stats == Map.new(~w(STR DEX CON INT WIS CHA), &{&1, 12})
      assert CC.points_spent(d) == 72
      assert CC.points_left(d) == 3
      assert d.race_picks == ["STR", "DEX"]
      assert CC.final_stats(d)["STR"] == 13
    end

    test "needs a typed name before it is valid" do
      assert {:error, [{:name, "type a name"}]} = CC.validate(draft())
      assert :ok = draft() |> named() |> CC.validate()
    end
  end

  describe "race and class" do
    test "a class re-suggests the stats and the race picks" do
      d = draft() |> CC.choose_class("warrior") |> ok!()

      assert d.base_stats["STR"] == 14
      assert d.base_stats["CON"] == 13
      assert CC.points_spent(d) == 75
      assert d.race_picks == ["STR", "CON"]
      assert CC.final_stats(d)["STR"] == 15
    end

    test "stats and picks the player set are kept when the class changes" do
      d =
        draft()
        |> CC.set_stat("CHA", 16)
        |> ok!()
        |> CC.pick_race_bonus(["CHA", "WIS"])
        |> ok!()
        |> CC.choose_class("warrior")
        |> ok!()

      assert d.base_stats["CHA"] == 16
      assert d.base_stats["STR"] == 12
      assert d.race_picks == ["CHA", "WIS"]
    end

    test "a new race resets the race picks" do
      d =
        draft()
        |> CC.pick_race_bonus(["CHA", "WIS"])
        |> ok!()
        |> CC.choose_race("dwarf")
        |> ok!()

      assert d.race_picks == []
      assert CC.race_modifiers(d) == %{"CON" => 2, "STR" => 1, "CHA" => -1}
      assert CC.final_stats(d)["CON"] == 14
    end

    test "Elf takes INT by default and can move the bonus to WIS" do
      d = draft() |> CC.choose_race("elf") |> ok!()
      assert d.race_picks == ["INT"]
      assert CC.race_modifiers(d) == %{"DEX" => 2, "INT" => 1, "CON" => -1}

      d = d |> CC.pick_race_bonus(["WIS"]) |> ok!()
      assert CC.race_modifiers(d) == %{"DEX" => 2, "WIS" => 1, "CON" => -1}
      assert CC.final_stats(d) |> Map.take(["INT", "WIS"]) == %{"INT" => 12, "WIS" => 13}

      cleric = draft() |> CC.choose_class("cleric") |> ok!() |> CC.choose_race("elf") |> ok!()
      assert cleric.race_picks == ["WIS"]
    end

    test "unknown labels and wrong picks are refused" do
      assert {:error, {:race, _}} = CC.choose_race(draft(), "dragon")
      assert {:error, {:class, _}} = CC.choose_class(draft(), "bard")
      assert {:error, {:race_picks, msg}} = CC.pick_race_bonus(draft(), ["STR"])
      assert msg =~ "choose 2 different stats"
      assert {:error, {:race_picks, _}} = CC.pick_race_bonus(draft(), ["STR", "STR"])
      assert {:error, {:race_picks, _}} = CC.pick_race_bonus(draft(), ["STR", "LUCK"])

      elf = draft() |> CC.choose_race("elf") |> ok!()

      assert {:error, {:race_picks, "the elf bonus goes to INT or WIS"}} =
               CC.pick_race_bonus(elf, ["CHA"])

      dwarf = draft() |> CC.choose_race("dwarf") |> ok!()

      assert {:error, {:race_picks, "dwarf has no stat choice"}} =
               CC.pick_race_bonus(dwarf, ["STR"])
    end
  end

  describe "the 75-point buy" do
    test "each base stat must be 3 to 18" do
      assert {:error, {:stats, "STR must be a whole number from 3 to 18"}} =
               CC.set_stat(draft(), "STR", 19)

      assert {:error, {:stats, _}} = CC.set_stat(draft(), "STR", 2)
      assert {:error, {:stats, _}} = CC.set_stat(draft(), "STR", "18")
      assert {:error, {:stats, "unknown stat \"LUCK\""}} = CC.set_stat(draft(), "LUCK", 10)
    end

    test "overspending is reported, underspending is allowed" do
      over = draft() |> named() |> CC.set_stat("STR", 16) |> ok!()
      assert CC.points_left(over) == -1
      assert {:error, [{:stats, "75 points at most; 76 spent"}]} = CC.validate(over)

      under = draft() |> named() |> CC.set_stat("STR", 8) |> ok!()
      assert CC.points_left(under) == 7
      assert :ok = CC.validate(under)
    end

    test "a race bonus that would pass 18 is an error, not a silent clamp" do
      d =
        draft()
        |> named()
        |> CC.choose_race("elf")
        |> ok!()
        |> CC.set_stat("DEX", 17)
        |> ok!()
        |> CC.set_stat("STR", 7)
        |> ok!()

      assert {:error, [{:stats, msg}]} = CC.validate(d)
      assert msg == "DEX would be 19 after the elf modifier (+2); it must be 3–18"
    end

    test "a race penalty that would drop below 3 is an error" do
      d = draft() |> named() |> CC.choose_race("dwarf") |> ok!() |> CC.set_stat("CHA", 3) |> ok!()

      assert {:error, [{:stats, "CHA would be 2 after the dwarf modifier (-1); it must be 3–18"}]} =
               CC.validate(d)
    end

    test "Human with no picks left is invalid" do
      d = %{named(draft()) | race_picks: []}
      assert {:error, [{:race_picks, "choose 2 stats for the human bonus"}]} = CC.validate(d)
    end
  end

  describe "the name" do
    test "is trimmed and limited to 40 characters" do
      assert {:ok, %Draft{name: "Wren Ashdown"}} = CC.set_name(draft(), "  Wren   Ashdown \n")

      assert {:error, {:name, "a name has at most 40 characters"}} =
               CC.set_name(draft(), String.duplicate("a", 41))
    end

    test "becomes a pc_ slug that can't clash with an NPC" do
      assert CC.slug("Wren Ashdown") == "pc_wren_ashdown"
      assert CC.slug("Björn Ødegård-Å") == "pc_bjorn_degard_a"
      assert CC.slug("innkeep") == "pc_innkeep"
      assert CC.slug("!!!") == "pc_"
    end
  end

  describe "finalize/1" do
    setup do
      d =
        draft()
        |> CC.choose_race("elf")
        |> ok!()
        |> CC.choose_class("ranger")
        |> ok!()
        |> CC.set_stat("CON", 14)
        |> ok!()
        |> CC.set_stat("CHA", 10)
        |> ok!()
        |> named("Sela Vorn")

      %{draft: d}
    end

    test "returns a valid pack-shaped character with the race modifiers kept", %{draft: d} do
      assert {:ok, c} = CC.finalize(d)

      assert c["id"] == "pc_sela_vorn"
      assert c["name"] == "Sela Vorn"
      assert {c["race"], c["class"]} == {"elf", "ranger"}
      # ranger leans DEX +2, WIS +1, so the elf pick defaults to WIS: DEX +2, WIS +1, CON -1
      assert c["stats"] == %{
               "STR" => 12,
               "DEX" => 16,
               "CON" => 13,
               "INT" => 12,
               "WIS" => 14,
               "CHA" => 10
             }

      assert c["skills"] == %{"ranged_combat" => 3, "tracking" => 2}
      assert c["wound_max"] == Mechanics.wound_max(%{"stats" => c["stats"]})
      assert c["coins"] == Defaults.rules(@adventure)["standings"]["commoner"]["coins"]
      assert [%{"id" => "travel_cloak"}, %{"id" => "hunting_knife"}] = c["inventory"]
      assert c["creation"]["points_spent"] == 75

      assert Pack.validate_player_character!(c, "test") == c
      assert :ok = Levers.validate!(c, "test")
      assert c["maslow"] == "esteem"
      assert [%{"focus" => "fame"}] = c["concerns"]
    end

    test "OCEAN is seeded per character: stable for a draft, can differ between drafts", %{
      draft: d
    } do
      {:ok, a} = CC.finalize(d)
      {:ok, b} = CC.finalize(d)
      assert a["ocean"] == b["ocean"]

      oceans =
        for i <- 1..12, do: CC.finalize(%{d | seed_key: "seed-#{i}"}) |> ok!() |> Map.get("ocean")

      assert length(Enum.uniq(oceans)) > 1
      assert Enum.all?(oceans, fn o -> Enum.all?(o, fn {_t, v} -> v in 1..10 end) end)
    end

    test "an invalid draft is not finalised" do
      assert {:error, [{:name, _}]} = CC.finalize(draft())
    end

    test "every race and class combination can be finalised from its suggestions" do
      opts = CC.options(@adventure)

      for race <- opts.races, class <- opts.classes do
        d =
          draft()
          |> CC.choose_race(race.id)
          |> ok!()
          |> CC.choose_class(class.id)
          |> ok!()
          |> named()

        assert {:ok, c} = CC.finalize(d), "#{race.id}/#{class.id}"
        assert Enum.all?(c["stats"], fn {_s, v} -> v in 3..18 end)
        assert Enum.all?(Map.keys(c["skills"]), &Map.has_key?(Mechanics.skill_stat_map(), &1))
      end
    end
  end
end
