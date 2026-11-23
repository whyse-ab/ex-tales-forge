defmodule TalesForge.IntentEval.ReadersRequestTest do
  use ExUnit.Case, async: true

  alias TalesForge.Game.{JevIntent, JevSelfCheck}
  alias TalesForge.IntentEval
  alias TalesForge.IntentEval.{JevOpts, Readers}

  @worlds "test/fixtures/intent_eval/worlds.json"
  @fixture "test/fixtures/intent_eval/items.jsonl"

  defp today(context, text) do
    candidates = JevIntent.candidates(context)
    questions = JevSelfCheck.ask(JevIntent.questions(candidates))
    state = JevIntent.state(context, text)
    %{candidates: candidates, state: state, questions: questions}
  end

  defp fixture_cases do
    worlds = IntentEval.load_worlds(@worlds)

    @fixture
    |> IntentEval.load_items()
    |> Enum.filter(&(&1["split"] == "tune"))
    |> Enum.map(fn item ->
      {item["id"], IntentEval.build_context(item, worlds), item["text"]}
    end)
  end

  test "default switches reproduce today's request byte for byte" do
    for {id, context, text} <- fixture_cases() do
      expected = today(context, text)
      actual = Readers.request(context, text, %JevOpts{})

      assert actual == expected, "#{id}: request maps differ under default switches"

      assert Jason.encode!(actual.state) == Jason.encode!(expected.state),
             "#{id}: state JSON differs under default switches"

      assert Readers.request_key(actual.state, actual.questions, "jev-1.13.0") ==
               Readers.request_key(expected.state, expected.questions, "jev-1.13.0"),
             "#{id}: cache key differs under default switches"
    end
  end

  test "an empty switches keyword is the same as today's request" do
    [{_id, context, text} | _] = fixture_cases()
    assert Readers.request(context, text) == today(context, text)
  end

  test "skill_split adds the split question only when on" do
    [{_id, context, text} | _] = fixture_cases()
    refute Keyword.has_key?(Readers.request(context, text).questions, :split)

    on = Readers.request(context, text, %JevOpts{skill_split: true})
    assert Keyword.has_key?(on.questions, :split)
    refute Keyword.has_key?(today(context, text).questions, :split)
  end

  test "context window defaults stay 800/600 and the wider limits keep more" do
    [{_id, context, _text} | _] = fixture_cases()
    narration = String.duplicate("N", 2000)
    text = String.duplicate("P", 1500)
    context = Map.put(context, "last_narration", narration)

    default = Readers.request(context, text)
    assert default.state["last_narration"] == String.slice(narration, -800, 800)
    assert default.state["player_text"] == String.slice(text, 0, 600)
    assert default.state["last_narration"] == today(context, text).state["last_narration"]
    assert default.state["player_text"] == today(context, text).state["player_text"]

    wide =
      Readers.request(context, text, %JevOpts{narration_chars: 1600, player_chars: 1200})

    assert wide.state["last_narration"] == String.slice(narration, -1600, 1600)
    assert wide.state["player_text"] == String.slice(text, 0, 1200)
    assert String.length(wide.state["last_narration"]) == 1600
    assert String.length(wide.state["player_text"]) == 1200
  end

  test "last_actions is omitted by default and sends up to the last 3 when on" do
    [{_id, context, text} | _] = fixture_cases()

    turns = [
      %{"action" => "first", "outcome" => "none"},
      %{"action" => "second", "outcome" => "ok"},
      %{"action" => "third", "outcome" => "none"},
      %{"action" => "fourth", "outcome" => "none"}
    ]

    context = Map.put(context, "recent_turns", turns)
    default = Readers.request(context, text)
    refute Map.has_key?(default.state, "last_player_actions")
    assert default.state == today(context, text).state

    on = Readers.request(context, text, %JevOpts{last_actions: true})
    assert on.state["last_player_actions"] == ["second", "third", "fourth"]

    empty =
      context
      |> Map.put("recent_turns", [])
      |> Readers.request(text, %JevOpts{last_actions: true})

    assert empty.state["last_player_actions"] == []
  end
end
