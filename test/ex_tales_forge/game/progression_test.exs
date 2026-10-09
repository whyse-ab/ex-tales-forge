defmodule TalesForge.Game.ProgressionTest do
  use ExUnit.Case, async: true

  alias TalesForge.Game.Progression

  doctest Progression

  @character %{
    "skills" => %{"climbing" => 3, "stealth" => 7},
    "learning_points" => %{},
    "learning_failures" => %{}
  }

  describe "spend_lp/3" do
    test "one attempt per whole LP; a roll of 11 or more that reaches the level succeeds" do
      character = put_in(@character, ["learning_points", "stealth"], 3.0)

      {spent, attempts} = Progression.spend_lp(character, %{"stealth" => [11, 12, 1]})

      assert Enum.map(attempts, &{&1["roll"], &1["raw_skill"], &1["improved"]}) ==
               [{11, 7, true}, {12, 8, true}, {1, 9, false}]

      assert spent["skills"]["stealth"] == 9
      assert spent["learning_points"]["stealth"] == 0.0
      assert Enum.all?(attempts, &(&1["lp_spent"] == 1))
    end

    test "a roll below the floor fails and still costs the LP" do
      character = put_in(@character, ["learning_points", "stealth"], 1.0)
      {spent, [attempt]} = Progression.spend_lp(character, %{"stealth" => 10})

      assert attempt["improved"] == false
      assert spent["skills"]["stealth"] == 7
      assert spent["learning_points"]["stealth"] == 0.0
    end

    test "above 11 the roll must also reach the level" do
      character =
        @character
        |> put_in(["skills", "stealth"], 14)
        |> put_in(["learning_points", "stealth"], 2.0)

      {spent, attempts} = Progression.spend_lp(character, %{"stealth" => [13, 14]})

      assert Enum.map(attempts, & &1["improved"]) == [false, true]
      assert spent["skills"]["stealth"] == 15
    end

    test "fractions stay for later; under 1 LP spends nothing" do
      character = put_in(@character, ["learning_points"], %{"climbing" => 0.5, "stealth" => 1.5})
      {spent, attempts} = Progression.spend_lp(character, %{"stealth" => 20})

      assert [%{"skill" => "stealth"}] = attempts
      assert spent["learning_points"] == %{"climbing" => 0.5, "stealth" => 0.5}
    end

    test "skills are spent in alphabetical order, each against its own level" do
      character =
        @character
        |> put_in(["skills", "stealth"], 13)
        |> put_in(["learning_points"], %{"stealth" => 1, "climbing" => 1})

      {spent, attempts} = Progression.spend_lp(character, %{"climbing" => 12, "stealth" => 12})

      assert Enum.map(attempts, &{&1["skill"], &1["improved"]}) ==
               [{"climbing", true}, {"stealth", false}]

      assert spent["skills"] == %{"climbing" => 4, "stealth" => 13}
    end

    test "only: spends just the listed skills; an empty list spends nothing" do
      character = put_in(@character, ["learning_points"], %{"stealth" => 1, "climbing" => 1})

      {spent, attempts} =
        Progression.spend_lp(character, %{"climbing" => 20, "stealth" => 20}, only: ["climbing"])

      assert Enum.map(attempts, & &1["skill"]) == ["climbing"]
      assert spent["learning_points"]["stealth"] == 1

      assert Progression.spend_lp(character, %{}, only: []) == {character, []}
    end

    test "an untrained skill (level 0) no longer learns on every attempt" do
      character = put_in(@character, ["learning_points", "tracking"], 2.0)
      {spent, attempts} = Progression.spend_lp(character, %{"tracking" => [1, 10]})

      assert Enum.map(attempts, &{&1["raw_skill"], &1["improved"]}) == [{0, false}, {0, false}]
      assert Map.get(spent["skills"], "tracking") == nil
    end

    test "past 20 no roll can succeed without a trainer" do
      character =
        @character
        |> put_in(["skills", "stealth"], 21)
        |> put_in(["learning_points", "stealth"], 2)

      {spent, attempts} = Progression.spend_lp(character, %{"stealth" => 20})

      assert Enum.map(attempts, & &1["improved"]) == [false, false]
      assert spent["skills"]["stealth"] == 21
    end

    test "LP stored as strings or integers count; a sheet without LP spends nothing" do
      character = put_in(@character, ["learning_points"], %{"climbing" => "1.0", "stealth" => 1})
      {_spent, attempts} = Progression.spend_lp(character, %{"climbing" => 20, "stealth" => 20})
      assert length(attempts) == 2

      assert Progression.spend_lp(%{"skills" => %{}}) == {%{"skills" => %{}}, []}
    end

    test "random rolls stay within 1..20 once the injected list runs out" do
      character = put_in(@character, ["learning_points", "climbing"], 3.0)
      {_spent, attempts} = Progression.spend_lp(character, %{"climbing" => [1]})

      assert length(attempts) == 3
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

  test "a long rest is six hours or more" do
    assert Progression.long_rest?(24)
    refute Progression.long_rest?(23)
  end
end
