defmodule TalesForge.Playtest.AffectLevelsTest do
  use ExUnit.Case, async: true

  alias TalesForge.Playtest.{AffectLevels, JevScorer}

  doctest AffectLevels

  test "Hawk is scored on one axis, real fair danger, with foreshadowing at level 2" do
    [l1, l2 | _] = AffectLevels.levels("hawk")
    assert l1 =~ "No danger"
    assert l1 =~ "rumours"
    assert l2 =~ "Foreshadowed"

    question = AffectLevels.turn_question("hawk", "Hawk", 3)
    assert question =~ "How much real, fair danger did Hawk face in turn 3 alone"
    refute question =~ "delighted"
  end

  test "Ronny's question matches his inverted levels: high = the game resisted him" do
    question = AffectLevels.session_question("ronny", "Ronny")
    assert question =~ "How firmly did the game resist Ronny"
    assert question =~ "high = it held firm"
    assert question =~ "fair in-world price"
    refute question =~ "delighted"
    assert AffectLevels.levels("ronny") |> List.first() =~ "Unlocked"
  end

  test "Paul, Lotta and Lars keep the frustrated-to-delighted question and rubric version" do
    for {id, hash} <- [{"paul", "dfec71a"}, {"lotta", "4545d3b"}, {"lars", "fc771be"}] do
      assert AffectLevels.session_question(id, "X") =~ "frustrated (low) to delighted (high)"
      assert AffectLevels.rubric_hash(id) == hash
    end
  end

  test "Hawk's and Ronny's rubric versions changed, so old and new scores never mix" do
    refute AffectLevels.rubric_hash("hawk") == "bfbd375"
    refute AffectLevels.rubric_hash("ronny") == "fe67670"
    assert JevScorer.rubric_version("hawk") == "jev-affect-v1-#{AffectLevels.rubric_hash("hawk")}"
  end

  test "the scorer asks each persona its own question" do
    persona = %{id: "hawk", name: "Hawk"}
    questions = JevScorer.questions(persona, [%{turn_number: 1}, %{turn_number: 2}])

    assert {session_q, levels} = questions[:persona_session_affect]
    assert session_q =~ "real, fair danger"
    assert levels == AffectLevels.levels("hawk")
    assert {turn_q, _} = questions[:persona_turn_affect_2]
    assert turn_q =~ "turn 2 alone"
  end
end
