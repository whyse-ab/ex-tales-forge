defmodule TalesForge.IntentEvalTest do
  use ExUnit.Case, async: true

  alias TalesForge.IntentEval

  setup do
    # Every Jev call in this process gets the same benign "speak" answer.
    Req.Test.stub(Jev.HTTP, fn conn ->
      Jev.Test.respond(conn,
        action: :speak,
        skill: :none,
        later: :none,
        safety: :benign,
        confidence: %{action: 0.9}
      )
    end)

    :ok
  end

  test "run scores the jev and heuristic readers and renders a report" do
    {report, results} =
      IntentEval.run(
        split: "tune",
        readers: [:jev, :heuristic],
        limit: 20,
        jev: [api_key: "test-key"]
      )

    assert is_binary(report)
    assert report =~ "# Intent evaluation"
    assert report =~ "## jev"
    assert report =~ "## heuristic"

    jev = results.metrics[:jev]
    assert jev.usable == 20
    assert jev.status_counts[:ok] == 20
    # Every stubbed answer is "speak", so action accuracy is a real number.
    assert is_number(jev.fields.action.rate)
  end

  test "the holdout split carries items and stays separate from tune" do
    tune =
      IntentEval.load_items("test/fixtures/intent_eval/items.jsonl")
      |> Enum.filter(&(&1["split"] == "tune"))

    hold =
      IntentEval.load_items("test/fixtures/intent_eval/items.jsonl")
      |> Enum.filter(&(&1["split"] == "holdout"))

    assert length(hold) > 0
    assert length(tune) > length(hold)

    assert MapSet.disjoint?(
             MapSet.new(Enum.map(tune, & &1["id"])),
             MapSet.new(Enum.map(hold, & &1["id"]))
           )
  end

  test "build_context turns a fixture item into a live intent context" do
    worlds = IntentEval.load_worlds("test/fixtures/intent_eval/worlds.json")

    item =
      IntentEval.load_items("test/fixtures/intent_eval/items.jsonl")
      |> Enum.find(&(&1["id"] == "h-q01"))

    context = IntentEval.build_context(item, worlds)

    assert context["variant"] == "default"
    assert is_list(context["present_npcs"])
    assert is_map(context["places"])
    assert context["location_id"] == item["context"]["location_id"]
  end
end
