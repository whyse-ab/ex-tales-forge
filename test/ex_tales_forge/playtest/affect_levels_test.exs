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
    for {id, hash} <- [{"paul", "7862783"}, {"lotta", "989546a"}, {"lars", "fc771be"}] do
      assert AffectLevels.session_question(id, "X") =~ "frustrated (low) to delighted (high)"
      assert AffectLevels.rubric_hash(id) == hash
    end
  end

  test "Paul's and Lotta's rubric versions never mix with the baseline or #69 scores" do
    for old <- ["dfec71a", "fd84ebb"], do: refute(AffectLevels.rubric_hash("paul") == old)
    for old <- ["4545d3b", "ce84a1a"], do: refute(AffectLevels.rubric_hash("lotta") == old)
    assert JevScorer.rubric_version("paul") == "jev-affect-v1-7862783"
    assert JevScorer.rubric_version("lotta") == "jev-affect-v1-989546a"
  end

  test "Paul's 4/5 border: a reply that only answers him is 4; evidence for 5 must be visible in the turn" do
    [_, _, _, pleased, delighted] = AffectLevels.levels("paul")
    assert pleased =~ "the reply only answers him"
    assert pleased =~ "adds nothing he did not ask for"
    assert pleased =~ "Example:"
    assert delighted =~ "each visible in this turn's narration"
    assert delighted =~ "an answer alone is not a consequence"
    assert delighted =~ "Information he asked for, a warm reply, a gift or a price never count"
    assert delighted =~ "Example:"
  end

  test "Lotta's 3/4 border: would another traveller saying her line get the same reply?" do
    [_, _, mixed, immersed, _] = AffectLevels.levels("lotta")
    assert mixed =~ "would read the same for any traveller who said her line"
    assert mixed =~ "her name used"
    assert immersed =~ "another traveller saying the same line would not get"
    assert immersed =~ "using her name or answering her question is not enough"
    assert mixed =~ "Example:" and immersed =~ "Example:"
  end

  test "Lars, Hawk and Ronny keep their rubric versions" do
    assert Enum.map(~w(lars hawk ronny), &AffectLevels.rubric_hash/1) ==
             ~w(fc771be 129f728 e8f0786)
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
