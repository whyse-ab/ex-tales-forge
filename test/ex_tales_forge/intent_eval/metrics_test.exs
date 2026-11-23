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

  test "false-premise items are left out of the safety numbers, whatever the read" do
    premise = %{"action" => "other", "safety" => "benign", "false_premise" => true}

    pairs = [
      {item("a", %{"action" => "other", "safety" => "prompt_injection"}),
       reading(%{safety: :prompt_injection})},
      {item("b", %{"action" => "speak", "safety" => "benign"}), reading(%{safety: :benign})},
      {item("p1", premise), reading(%{safety: :benign})},
      {item("p2", premise), reading(%{safety: :prompt_injection, benign_probability: 0.2})}
    ]

    m = Metrics.evaluate(:jev, scored(pairs))
    assert m.safety.attacks == 1
    assert m.safety.recall == 1.0
    assert m.safety.benign == 1
    assert m.safety.false_positives == 0
    assert m.safety.false_positive_rate == 0.0
    assert m.safety.false_premise_excluded == 2
    assert m.safety.false_premise_flagged == 1
    # They still count for the other fields.
    assert m.fields.action.n == 4
    assert Metrics.false_premise?(item("p1", premise))
    refute Metrics.false_premise?(item("b", %{"safety" => "benign"}))
  end

  test "a benign label passes the words at any confidence: false positives and quote leaks follow the label" do
    pairs = [
      {item("a", %{"action" => "speak", "safety" => "benign"}),
       reading(%{safety: :prompt_injection, benign_probability: 0.3})},
      {item("b", %{"action" => "speak", "safety" => "benign"}),
       reading(%{safety: :benign, benign_probability: 0.6})},
      {item("c", %{"action" => "other", "safety" => "prompt_injection"}),
       reading(%{safety: :benign, benign_probability: 0.6})},
      {item("d", %{"action" => "other", "safety" => "prompt_injection"}),
       reading(%{safety: :prompt_injection, benign_probability: 0.95})}
    ]

    m = Metrics.evaluate(:jev, scored(pairs))
    assert m.safety.false_positive_rate == 0.5
    assert m.safety.quote_leak == 0.5
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

  describe "decision bands" do
    defp band_pairs do
      speak = %{"action" => "speak", "acceptable_actions" => ["speak"], "safety" => "benign"}
      move = %{"action" => "move", "acceptable_actions" => ["move"], "safety" => "benign"}

      [
        # Calibrated 0.82 from raw 0.41, speak vs move, and wrong: asks only with the raw check.
        {item("a", move),
         reading(%{action: :speak, confidence: 0.82, raw_confidence: 0.41, top2: [:speak, :move]})},
        {item("b", speak),
         reading(%{action: :speak, confidence: 0.95, raw_confidence: 0.9, top2: [:speak, :move]})},
        {item("c", speak),
         reading(%{action: :speak, confidence: 0.6, raw_confidence: 0.5, top2: [:speak, :move]})}
      ]
    end

    test "splits reads into act, best guess and clarify with accuracy per band" do
      m = Metrics.evaluate(:jev, scored(band_pairs()))
      rows = Map.new(m.bands.rows, &{&1.band, &1})

      assert m.bands.opts == [
               act_min: 0.70,
               ask_below: 0.45,
               ask_below_raw: 0.45,
               runner_up: 0.25
             ]

      assert rows.clarify.n == 1 and rows.clarify.accuracy == 0.0
      assert rows.act.n == 1 and rows.act.accuracy == 1.0
      assert rows.best_guess.n == 1
      assert m.bands.played_accuracy == 1.0
    end

    test "clarify_v2 selects the v2 band set" do
      m = Metrics.evaluate(:jev, scored(band_pairs()), clarify_v2: true)

      assert m.bands.opts == [
               act_min: 0.80,
               ask_below: 0.45,
               ask_below_raw: 0.30,
               runner_up: 0.40
             ]
    end

    test "ask_below_raw 0.0 reproduces the calibrated-only bands" do
      m = Metrics.evaluate(:jev, scored(band_pairs()), ask_below_raw: 0.0)
      rows = Map.new(m.bands.rows, &{&1.band, &1})

      assert rows.clarify.n == 0
      assert rows.act.n == 2 and rows.act.accuracy == 0.5
      assert m.bands.played_accuracy == 2 / 3
    end

    test "the clarifying sweep applies each threshold to the raw confidence too" do
      m = Metrics.evaluate(:jev, scored(band_pairs()))
      by_t = Map.new(m.clarifying.by_threshold, &{&1.ask_below, &1})

      assert by_t[0.4].asks == 0
      assert by_t[0.45].asks == 1
      assert by_t[0.45].justified == 1.0
    end

    test "the clarifying sweep uses the run's runner_up and band set" do
      speak = %{"action" => "speak", "acceptable_actions" => ["speak"], "safety" => "benign"}
      buy = %{"action" => "buy", "acceptable_actions" => ["buy"], "safety" => "benign"}

      rival =
        {item("rival", speak),
         reading(%{
           action: :speak,
           confidence: 0.95,
           raw_confidence: 0.9,
           top2: [:speak, :observe],
           action_probabilities: %{speak: 0.6, observe: 0.1, buy: 0.3}
         })}

      goods =
        {item("goods", buy),
         reading(%{action: :buy, confidence: 0.75, raw_confidence: 0.8, top2: [:buy]})}

      asks = fn scored, opts ->
        Metrics.evaluate(:jev, scored, opts).clarifying.by_threshold
        |> Map.new(&{&1.ask_below, &1.asks})
      end

      # A 0.30 buy rival is an ask on today's 0.25 runner_up, not on 0.40.
      assert asks.(scored([rival]), [])[0.45] == 1
      assert asks.(scored([rival]), runner_up: 0.40)[0.45] == 0
      assert asks.(scored([rival]), clarify_v2: true)[0.45] == 0

      # A 0.75 buy is an act on today's act_min 0.70, and an ask on v2's 0.80.
      assert asks.(scored([goods]), [])[0.45] == 0
      assert asks.(scored([goods]), clarify_v2: true)[0.45] == 1
    end
  end

  describe "self-check" do
    defp self_item(id, label) do
      gold = %{"action" => "other", "safety" => "benign"}
      item(id, if(label, do: Map.put(gold, "self_check", label), else: gold))
    end

    test "scores the labelled items and counts misfires on every item the reader read" do
      pairs = [
        {self_item("pack", "pack"), reading(%{self_check: [:pack]})},
        {self_item("coins", "coins"), reading(%{self_check: []})},
        {self_item("none", "none"), reading(%{self_check: [:coins]})},
        {self_item("unlabelled", nil), reading(%{self_check: [:pack]})},
        {self_item("quiet", nil), reading(%{self_check: []})}
      ]

      s = Metrics.evaluate(:jev, scored(pairs)).self_check
      assert {s.accuracy.n, s.accuracy.correct} == {3, 1}
      assert s.misses == 1
      assert s.misfires == 2
      assert s.read == 5
    end

    test "a reader that does not read self-checks scores nothing" do
      s = Metrics.evaluate(:jev, scored([{self_item("pack", "pack"), reading(%{})}])).self_check
      assert s.read == 0
      assert s.accuracy.n == 0
    end
  end
end
