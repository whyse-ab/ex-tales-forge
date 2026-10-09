defmodule TalesForge.IntentEval.FixtureTest do
  use ExUnit.Case, async: true

  alias TalesForge.Game.Mechanics
  alias TalesForge.IntentEval

  @items IntentEval.load_items("test/fixtures/intent_eval/items.jsonl")

  # Categories added after the holdout was frozen. They live in the tune split
  # only (never the holdout), so they are left out of the stratification check,
  # and their agent-draft labels may still wait for Case's review (README,
  # "Tune-only additions").
  @tune_only_categories ~w(attack_false_premise)

  defp tune_only?(item), do: item["category"] in @tune_only_categories

  test "the fixture validates" do
    assert IntentEval.validate(@items) == :ok
  end

  test "ids are unique" do
    ids = Enum.map(@items, & &1["id"])
    assert length(ids) == length(Enum.uniq(ids))
  end

  test "every label is reviewed, with a labeller (tune-only additions may await review)" do
    assert @items |> Enum.reject(&tune_only?/1) |> Enum.all?(&(&1["reviewed"] == true))
    assert Enum.all?(@items, &is_boolean(&1["reviewed"]))
    assert Enum.all?(@items, &is_binary(&1["labeller"]))
  end

  test "tune-only additions are in the tune split and are flagged as attacks" do
    added = Enum.filter(@items, &tune_only?/1)
    assert length(added) >= 10
    assert Enum.all?(added, &(&1["split"] == "tune"))
    assert Enum.all?(added, &(get_in(&1, ["gold", "safety"]) != "benign"))
  end

  test "there are at least 300 items with both real and handwritten sources" do
    assert length(@items) >= 300
    sources = @items |> Enum.map(& &1["source"]) |> Enum.uniq() |> Enum.sort()
    assert sources == ["handwritten", "real_playtest"]
  end

  test "about 60 attacks across the three attack classes, in both splits" do
    attacks = Enum.filter(@items, &(get_in(&1, ["gold", "safety"]) != "benign"))
    assert length(attacks) >= 55

    classes = attacks |> Enum.map(&get_in(&1, ["gold", "safety"])) |> Enum.uniq() |> Enum.sort()
    assert classes == ["jailbreak", "nefarious", "prompt_injection"]

    by_split = Enum.frequencies_by(attacks, & &1["split"])
    assert by_split["tune"] > 0
    assert by_split["holdout"] > 0
  end

  test "the holdout is roughly 30% and stratified by category" do
    by_cat = @items |> Enum.reject(&tune_only?/1) |> Enum.group_by(& &1["category"])

    for {_cat, group} <- by_cat, length(group) >= 8 do
      held = Enum.count(group, &(&1["split"] == "holdout"))
      frac = held / length(group)
      assert frac >= 0.2 and frac <= 0.4
    end
  end

  test "the fixture skill vocabulary matches the game's skills" do
    gold_skills =
      @items
      |> Enum.flat_map(fn item ->
        [get_in(item, ["gold", "skill"]) | List.wrap(get_in(item, ["gold", "acceptable_skills"]))]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    valid = Mechanics.skill_stat_map() |> Map.keys()
    assert Enum.all?(gold_skills, &(&1 in valid))
  end
end
