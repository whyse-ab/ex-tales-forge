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
    for {id, hash} <- [{"paul", "df3c861"}, {"lotta", "989546a"}, {"lars", "fc771be"}] do
      assert AffectLevels.session_question(id, "X") =~ "frustrated (low) to delighted (high)"
      assert AffectLevels.rubric_hash(id) == hash
    end
  end

  test "Paul's and Lotta's rubric versions never mix with the baseline or #69 scores" do
    for old <- ["dfec71a", "fd84ebb", "7862783"],
        do: refute(AffectLevels.rubric_hash("paul") == old)

    for old <- ["4545d3b", "ce84a1a"], do: refute(AffectLevels.rubric_hash("lotta") == old)
    assert JevScorer.rubric_version("paul") == "jev-affect-v1-df3c861"
    assert JevScorer.rubric_version("lotta") == "jev-affect-v1-989546a"
  end

  test "Paul's 4/5 border: a vivid answer or new fact is 4; 5 needs a consequence of his own choice" do
    [_, _, _, pleased, delighted] = AffectLevels.levels("paul")
    assert pleased =~ "A vivid or rich answer is a 4"

    assert pleased =~
             "new fact, rumour or detail volunteered with it, even one he did not ask about"

    assert pleased =~ "polite guest"
    assert pleased =~ "Example:"
    assert delighted =~ "a consequence of his own choice or discovery"
    assert delighted =~ "an NPC acts on what he learned or offered"
    assert delighted =~ "a door opens or a way forward appears because he asked"

    assert delighted =~
             "A vivid answer, a new fact, a warm reply, a gift or a price is never a consequence"

    assert delighted =~ "visible in this turn's narration"
    assert delighted =~ "uneventful stretch is never this level"
    assert delighted =~ "Example:"
    refute delighted =~ "at least two of"
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

  test "Lotta's top level needs concrete evidence, not just a pleasant stretch" do
    [_, _, mixed, pleased, top] = AffectLevels.levels("lotta")
    assert mixed =~ "interchangeable"
    assert pleased =~ "polite guest"
    assert top =~ "concrete evidence of at least two of"
    assert top =~ "surprise"
    assert top =~ "consequence"
    assert top =~ "calling back"
    assert top =~ "own goals"
    assert top =~ "uneventful stretch is never this level"
    assert top =~ "care shown when stakes hurt"
    assert Enum.at(AffectLevels.levels("paul"), 2) =~ "generic"
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
