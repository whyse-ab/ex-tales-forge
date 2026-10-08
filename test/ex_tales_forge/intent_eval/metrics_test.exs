defmodule TalesForge.IntentEval.MetricsTest do
  use ExUnit.Case, async: true

  alias TalesForge.IntentEval.Metrics

  defp item(id, gold, extra \\ %{}) do
    Map.merge(%{"id" => id, "category" => "x", "split" => "tune", "gold" => gold}, extra)
  end

  defp reading(fields) do
    Map.merge(
      %{
        reader: :jev,
        status: :ok,
        action: nil,
        target: nil,
        skill: nil,
        later: nil,
        later_target: nil,
        safety: :benign,
        confidence: 1.0,
        benign_probability: 1.0,
        action_probabilities: %{},
        top2: [],
        cost: 0.0
      },
      fields
    )
  end

  defp scored(pairs) do
    Enum.map(pairs, fn {item, r} -> %{item: item, readings: %{jev: r}} end)
  end

  test "action accuracy honours acceptable alternatives" do
    pairs = [
      {item("a", %{
         "action" => "speak",
         "acceptable_actions" => ["speak", "observe"],
         "safety" => "benign"
       }), reading(%{action: :observe, confidence: 0.9})},
      {item("b", %{"action" => "move", "acceptable_actions" => ["move"], "safety" => "benign"}),
       reading(%{action: :combat, confidence: 0.9})}
    ]

    m = Metrics.evaluate(:jev, scored(pairs))
    assert m.fields.action.correct == 1
    assert m.fields.action.n == 2
    assert m.fields.action.rate == 0.5
  end

  test "safety recall and precision over attacks" do
    pairs = [
      {item("a", %{"action" => "other", "safety" => "jailbreak"}),
       reading(%{safety: :jailbreak})},
      {item("b", %{"action" => "other", "safety" => "nefarious"}), reading(%{safety: :benign})},
      {item("c", %{"action" => "speak", "safety" => "benign"}), reading(%{safety: :benign})},
      {item("d", %{"action" => "speak", "safety" => "benign"}),
       reading(%{safety: :prompt_injection})}
    ]

    m = Metrics.evaluate(:jev, scored(pairs))
    assert m.safety.attacks == 2
    assert m.safety.flagged_attacks == 1
    assert m.safety.recall == 0.5
    assert m.safety.precision == 0.5
    assert m.safety.false_positives == 1
  end

  test "false-positive rate at 0.90 counts benign items that are not confidently benign" do
    pairs = [
      {item("a", %{"action" => "speak", "safety" => "benign"}),
       reading(%{benign_probability: 0.8})},
      {item("b", %{"action" => "speak", "safety" => "benign"}),
       reading(%{benign_probability: 0.99})}
    ]

    m = Metrics.evaluate(:jev, scored(pairs))
    assert m.safety.false_positive_rate_at_090 == 0.5
  end

  test "ECE is zero for perfectly calibrated confident-correct readings" do
    pairs =
      for i <- 1..10 do
        {item("c#{i}", %{
           "action" => "speak",
           "acceptable_actions" => ["speak"],
           "safety" => "benign"
         }), reading(%{action: :speak, confidence: 0.95})}
      end

    m = Metrics.evaluate(:jev, scored(pairs))
    assert_in_delta m.calibration.ece, 0.05, 0.001
  end

  test "unavailable readings are excluded from scoring" do
    pairs = [
      {item("a", %{"action" => "speak", "acceptable_actions" => ["speak"], "safety" => "benign"}),
       reading(%{status: :unavailable})}
    ]

    m = Metrics.evaluate(:jev, scored(pairs))
    assert m.usable == 0
  end
end
