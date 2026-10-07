defmodule TalesForge.Characters.DefaultsTest do
  use ExUnit.Case, async: true

  alias TalesForge.Characters.{Defaults, Levers}
  alias TalesForge.Game.{Mechanics, Pack}

  @rules Defaults.rules()

  describe "derive/3" do
    test "a journeyman innkeep: core skills at the tier, secondary at half, deterministic" do
      d = Defaults.derive(%{"occupation" => "innkeep"}, @rules, 1)

      assert d["skills"] == %{"persuasion" => 8, "insight" => 8, "etiquette" => 4}
      assert d["maslow"] == "belonging"
      assert [%{"focus" => "regulars"}] = d["concerns"]
      assert d["coins"] == %{"gold" => 0, "silver" => 20, "copper" => 300}

      for seed <- 1..50 do
        assert Defaults.derive(%{"occupation" => "innkeep"}, @rules, seed)["skills"] ==
                 d["skills"]
      end
    end

    test "seniority sets the tier; class skills add at 3 without lowering a job skill" do
      master = Defaults.derive(%{"occupation" => "guard", "seniority" => "master"}, @rules, 1)
      assert master["skills"]["melee_combat"] == 12
      assert master["skills"]["insight"] == 6

      warrior_guard = Defaults.derive(%{"occupation" => "guard", "class" => "warrior"}, @rules, 1)
      assert warrior_guard["skills"]["melee_combat"] == 8
      assert warrior_guard["skills"]["tactics"] == 4
    end

    test "stats and OCEAN vary by at most one around race + class + occupation, stable per seed" do
      for seed <- 1..200 do
        d =
          Defaults.derive(
            %{"race" => "dwarf", "class" => "warrior", "occupation" => "miner"},
            @rules,
            seed
          )

        # dwarf CON +2, warrior CON +1
        assert d["stats"]["CON"] in 12..14
        # dwarf CHA -1
        assert d["stats"]["CHA"] in 8..10
        # dwarf C +2, miner C +1
        assert d["ocean"]["conscientiousness"] in 7..9
        assert Enum.all?(d["ocean"], fn {_t, v} -> v in 1..10 end)

        assert d ==
                 Defaults.derive(
                   %{"race" => "dwarf", "class" => "warrior", "occupation" => "miner"},
                   @rules,
                   seed
                 )
      end

      values = for seed <- 1..200, do: Defaults.derive(%{}, @rules, seed)["stats"]["STR"]
      assert Enum.sort(Enum.uniq(values)) == [9, 10, 11]
    end

    test "standing can lower the Maslow need and adds its concern; at most three concerns" do
      d = Defaults.derive(%{"occupation" => "noble", "standing" => "underclass"}, @rules, 1)
      assert d["maslow"] == "safety"
      assert Enum.map(d["concerns"], & &1["focus"]) == ["survival", "family"]

      high = Defaults.derive(%{"occupation" => "laborer", "standing" => "nobility"}, @rules, 1)
      assert high["maslow"] == "safety"
    end

    test "every derived character passes the lever checks" do
      for occ <- Map.keys(@rules["occupations"]),
          race <- Map.keys(@rules["races"]),
          standing <- Map.keys(@rules["standings"]) do
        d =
          Defaults.derive(
            %{"occupation" => occ, "race" => race, "standing" => standing},
            @rules,
            7
          )

        assert :ok = Levers.validate!(d, "#{occ}/#{race}/#{standing}")
        assert Enum.all?(Map.keys(d["skills"]), &Map.has_key?(Mechanics.skill_stat_map(), &1))
      end
    end

    test "unknown labels raise" do
      assert_raise ArgumentError, ~r/unknown occupation "wizard_king"/, fn ->
        Defaults.derive(%{"occupation" => "wizard_king"}, @rules, 1)
      end

      assert_raise ArgumentError, ~r/x\.json: unknown race "orc"/, fn ->
        Defaults.validate_inputs!(%{"race" => "orc"}, @rules, "x.json")
      end
    end
  end

  describe "seed/2" do
    test "depends on session and character key, and is stable" do
      assert Defaults.seed("s1", "innkeep") == Defaults.seed("s1", "innkeep")
      refute Defaults.seed("s1", "innkeep") == Defaults.seed("s2", "innkeep")
      refute Defaults.seed("s1", "innkeep") == Defaults.seed("s1", "prospector")
    end
  end

  describe "merge/2 and apply/3" do
    test "maps merge per key, other keys replace, a skill of 0 is removed" do
      defaults = %{
        "skills" => %{"persuasion" => 8, "insight" => 8},
        "ocean" => %{"openness" => 5, "neuroticism" => 5},
        "maslow" => "safety",
        "concerns" => [%{"text" => "a"}]
      }

      merged =
        Defaults.merge(defaults, %{
          "skills" => %{"persuasion" => 9, "insight" => 0},
          "ocean" => %{"neuroticism" => 7},
          "maslow" => "belonging",
          "concerns" => [%{"text" => "b"}],
          "name" => "Sour Barkeep"
        })

      assert merged["skills"] == %{"persuasion" => 9}
      assert merged["ocean"] == %{"openness" => 5, "neuroticism" => 7}
      assert merged["maslow"] == "belonging"
      assert merged["concerns"] == [%{"text" => "b"}]
      assert merged["name"] == "Sour Barkeep"
    end

    test "apply keeps authored keys and OCEAN from personality_traits" do
      traits = %{
        "openness" => 4,
        "conscientiousness" => 8,
        "extraversion" => 5,
        "agreeableness" => 6,
        "neuroticism" => 5
      }

      definition = %{
        "id" => "innkeep",
        "race" => "human",
        "derive" => %{"occupation" => "innkeep"},
        "motivations" => %{"personality_traits" => traits},
        "maslow" => "belonging",
        "concerns" => [%{"text" => "Keep the inn"}]
      }

      applied = Defaults.apply(definition, @rules, 123)
      assert applied["ocean"] == traits
      assert applied["motivations"]["personality_traits"] == traits
      assert applied["skills"]["persuasion"] == 8
      assert applied["concerns"] == [%{"text" => "Keep the inn"}]
      assert map_size(applied["stats"]) == 6
      assert applied["derive"] == definition["derive"]
    end

    test "a definition without derive is unchanged" do
      assert Defaults.apply(%{"id" => "x"}, @rules, 1) == %{"id" => "x"}
    end
  end

  describe "rules/1" do
    test "the Tin Valley pack adds occupations to the base" do
      tv = Defaults.rules("tin_valley")
      assert Map.has_key?(tv["occupations"], "prospector")
      refute Map.has_key?(@rules["occupations"], "prospector")
      assert Map.keys(tv["races"]) == Map.keys(@rules["races"])
      assert Defaults.rules("crossroads_ledger") == @rules
    end

    test "a pack may add labels but not redefine a base one or add unknown keys or skills" do
      occ = %{
        "core" => ["tracking"],
        "secondary" => [],
        "ocean" => %{},
        "maslow" => "safety",
        "concerns" => []
      }

      assert Defaults.extend_rules!(@rules, %{"occupations" => %{"trapper" => occ}}, "p")[
               "occupations"
             ]["trapper"]

      assert_raise ArgumentError, ~r/cannot redefine base occupations \["innkeep"\]/, fn ->
        Defaults.extend_rules!(@rules, %{"occupations" => %{"innkeep" => occ}}, "p")
      end

      assert_raise ArgumentError, ~r/unknown key "spells"/, fn ->
        Defaults.extend_rules!(@rules, %{"spells" => %{}}, "p")
      end

      assert_raise ArgumentError, ~r/unknown skills \["juggling"\]/, fn ->
        Defaults.extend_rules!(
          @rules,
          %{"occupations" => %{"jester" => %{occ | "core" => ["juggling"]}}},
          "p"
        )
      end

      assert_raise ArgumentError, ~r/unknown concern focus "boredom"/, fn ->
        bad = %{occ | "concerns" => [%{"text" => "t", "focus" => "boredom"}]}
        Defaults.extend_rules!(@rules, %{"occupations" => %{"idler" => bad}}, "p")
      end

      assert_raise ArgumentError, ~r/unknown Maslow level "wealth"/, fn ->
        Defaults.extend_rules!(
          @rules,
          %{"occupations" => %{"miser" => %{occ | "maslow" => "wealth"}}},
          "p"
        )
      end

      assert_raise ArgumentError, ~r/unknown stats \["LUCK"\]/, fn ->
        Defaults.extend_rules!(
          @rules,
          %{"races" => %{"orc" => %{"stats" => %{"LUCK" => 1}, "ocean" => %{}}}},
          "p"
        )
      end

      assert_raise ArgumentError, ~r/unknown OCEAN traits \["charm"\]/, fn ->
        Defaults.extend_rules!(
          @rules,
          %{"races" => %{"orc" => %{"stats" => %{}, "ocean" => %{"charm" => 1}}}},
          "p"
        )
      end

      assert Defaults.extend_rules!(@rules, %{"concern_focuses" => ["boredom"]}, "p")[
               "concern_focuses"
             ]
             |> Enum.member?("boredom")
    end

    test "every authored NPC derive block resolves" do
      tv = Defaults.rules("tin_valley")

      for npc <- Pack.load("tin_valley").npcs, inputs = npc["derive"] do
        assert :ok = Defaults.validate_inputs!(inputs, tv, npc["id"])
      end

      dir = Path.join(:code.priv_dir(:ex_tales_forge), "npcs")

      for file <- Path.wildcard(Path.join(dir, "*.json")),
          inputs = Jason.decode!(File.read!(file))["derive"] do
        assert :ok = Defaults.validate_inputs!(inputs, @rules, file)
      end
    end
  end
end
