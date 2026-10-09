defmodule TalesForge.Game.ProgressionTest do
  use ExUnit.Case, async: true

  alias TalesForge.Game.Progression

  doctest Progression

  @character %{
    "skills" => %{"climbing" => 3, "stealth" => 7},
    "learning_points" => %{},
    "learning_failures" => %{}
  }

  describe "resolve_rest/3" do
    test "rolls until the first success: +1 at most, then every LP of the skill is gone" do
      character = put_in(@character, ["learning_points", "climbing"], 3.0)

      {rested, attempts, []} = Progression.resolve_rest(character, %{"climbing" => [4, 11, 20]})

      assert Enum.map(attempts, &{&1["roll"], &1["improved"]}) == [{4, false}, {11, true}]
      assert List.last(attempts)["lp_cleared"] == 1
      assert rested["skills"]["climbing"] == 4
      assert rested["learning_points"]["climbing"] == 0.0
    end

    test "when every roll fails the LP are gone too: nothing carries over" do
      character = put_in(@character, ["learning_points", "climbing"], 2.0)

      {rested, attempts, []} = Progression.resolve_rest(character, %{"climbing" => [1, 10]})

      assert Enum.map(attempts, & &1["improved"]) == [false, false]
      assert List.last(attempts)["lp_cleared"] == 0
      assert rested["skills"]["climbing"] == 3
      assert rested["learning_points"]["climbing"] == 0.0
    end

    test "higher levels need more LP per roll; too few for one roll are dropped" do
      # stealth 7 costs 3 LP per roll: 7 LP buy two rolls, 2 LP buy none
      seven = put_in(@character, ["learning_points", "stealth"], 7.0)
      {_r, attempts, []} = Progression.resolve_rest(seven, %{"stealth" => [1, 2]})
      assert Enum.map(attempts, & &1["lp_spent"]) == [3, 3]
      assert List.last(attempts)["lp_cleared"] == 1

      two = put_in(@character, ["learning_points", "stealth"], 2.0)
      {rested, [], []} = Progression.resolve_rest(two, %{"stealth" => 20})
      assert rested["learning_points"]["stealth"] == 0.0
      assert rested["skills"]["stealth"] == 7
    end

    test "from level 10 the LP stay banked unless the character reflected on the skill" do
      character =
        @character
        |> put_in(["skills", "stealth"], 10)
        |> put_in(["learning_points", "stealth"], 4.0)

      {kept, [], ["stealth"]} = Progression.resolve_rest(character, %{"stealth" => 20})
      assert kept["learning_points"]["stealth"] == 4.0
      assert kept["skills"]["stealth"] == 10

      {rested, [attempt], []} =
        Progression.resolve_rest(character, %{"stealth" => 20}, reflected: ["stealth"])

      assert {attempt["improved"], attempt["lp_spent"]} == {true, 4}
      assert {rested["skills"]["stealth"], rested["learning_points"]["stealth"]} == {11, 0.0}
    end

    test "skills are resolved independently, in alphabetical order" do
      character = put_in(@character, ["learning_points"], %{"stealth" => 3, "climbing" => 1})

      {rested, attempts, []} =
        Progression.resolve_rest(character, %{"climbing" => 12, "stealth" => 12})

      assert Enum.map(attempts, &{&1["skill"], &1["improved"]}) ==
               [{"climbing", true}, {"stealth", true}]

      assert rested["skills"] == %{"climbing" => 4, "stealth" => 8}
    end

    test "only: resolves just the listed skills; an empty list resolves nothing" do
      character = put_in(@character, ["learning_points"], %{"stealth" => 3, "climbing" => 1})

      {rested, attempts, []} =
        Progression.resolve_rest(character, %{"climbing" => 20}, only: ["climbing"])

      assert Enum.map(attempts, & &1["skill"]) == ["climbing"]
      assert rested["learning_points"]["stealth"] == 3

      assert Progression.resolve_rest(character, %{}, only: []) == {character, [], []}
    end

    test "an untrained skill (level 0) needs a roll of 11 like any other" do
      character = put_in(@character, ["learning_points", "tracking"], 2.0)
      {rested, attempts, []} = Progression.resolve_rest(character, %{"tracking" => [1, 10]})

      assert Enum.map(attempts, &{&1["raw_skill"], &1["improved"]}) == [{0, false}, {0, false}]
      assert Map.get(rested["skills"], "tracking") == nil
    end

    test "LP stored as strings or integers count; a sheet without LP resolves nothing" do
      character = put_in(@character, ["learning_points"], %{"climbing" => "1.0", "stealth" => 3})

      {_r, attempts, []} =
        Progression.resolve_rest(character, %{"climbing" => 20, "stealth" => 20})

      assert length(attempts) == 2

      assert Progression.resolve_rest(%{"skills" => %{}}) == {%{"skills" => %{}}, [], []}
    end

    test "random rolls stay within 1..20 once the injected list runs out" do
      character = put_in(@character, ["learning_points", "climbing"], 3.0)
      {_r, attempts, []} = Progression.resolve_rest(character, %{"climbing" => [1]})

      assert length(attempts) in 1..3
      assert Enum.all?(attempts, &(&1["roll"] in 1..20))
    end
  end

  describe "train/3" do
    test "a free attempt: no LP spent, +5 on the roll" do
      character =
        @character
        |> put_in(["skills", "stealth"], 16)
        |> put_in(["learning_points", "stealth"], 0.5)

      {hit, hit_entry} = Progression.train(character, "stealth", %{"stealth" => 11})
      {miss, miss_entry} = Progression.train(character, "stealth", %{"stealth" => 10})

      assert {hit_entry["improved"], hit["skills"]["stealth"]} == {true, 17}
      assert {miss_entry["improved"], miss["skills"]["stealth"]} == {false, 16}
      assert hit["learning_points"]["stealth"] == 0.5
      assert hit_entry["bonus"] == 5
    end

    test "the trainer's +5 counts toward the floor of 11 too" do
      character = put_in(@character, ["skills", "stealth"], 2)
      {hit, _} = Progression.train(character, "stealth", %{"stealth" => 6})
      {miss, _} = Progression.train(character, "stealth", %{"stealth" => 5})

      assert {hit["skills"]["stealth"], miss["skills"]["stealth"]} == {3, 2}
    end

    test "a trainer can take a skill past 20" do
      character = put_in(@character, ["skills", "stealth"], 22)
      {trained, _entry} = Progression.train(character, "stealth", %{"stealth" => 17})
      assert trained["skills"]["stealth"] == 23
    end
  end

  test "success chance is (21 - max(level, 11)) / 20: at most a coin flip" do
    assert Enum.map([0, 3, 11, 12, 16, 20], &Progression.success_chance/1) ==
             [0.5, 0.5, 0.5, 0.45, 0.25, 0.05]
  end

  test "LP per roll is ceil(level / 3), at least 1" do
    assert Enum.map([0, 1, 3, 4, 9, 10, 12, 13, 20], &Progression.lp_per_roll/1) ==
             [1, 1, 1, 2, 3, 4, 4, 5, 7]
  end

  test "a long rest is six hours or more" do
    assert Progression.long_rest?(24)
    refute Progression.long_rest?(23)
  end
end
