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

  test "Paul, Lotta and Lars keep the frustrated-to-delighted question; only Lars keeps his version" do
    for {id, hash} <- [{"paul", "fd84ebb"}, {"lotta", "ce84a1a"}, {"lars", "fc771be"}] do
      assert AffectLevels.session_question(id, "X") =~ "frustrated (low) to delighted (high)"
      assert AffectLevels.rubric_hash(id) == hash
    end
  end

  test "Paul's and Lotta's stricter rubric versions never mix with the baseline scores" do
    refute AffectLevels.rubric_hash("paul") == "dfec71a"
    refute AffectLevels.rubric_hash("lotta") == "4545d3b"
    assert JevScorer.rubric_version("paul") == "jev-affect-v1-fd84ebb"
    assert JevScorer.rubric_version("lotta") == "jev-affect-v1-ce84a1a"
  end

  test "Paul's and Lotta's top level needs concrete evidence, not just a pleasant stretch" do
    for id <- ["paul", "lotta"] do
      [_, _, mixed, pleased, top] = AffectLevels.levels(id)
      assert mixed =~ "generic" or mixed =~ "interchangeable"
      assert pleased =~ "polite guest"
      assert top =~ "concrete evidence of at least two of"
      assert top =~ "surprise"
      assert top =~ "consequence"
      assert top =~ "calling back"
      assert top =~ "own goals"
      assert top =~ "uneventful stretch is never this level"
    end

    assert List.last(AffectLevels.levels("lotta")) =~ "care shown when stakes hurt"
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
