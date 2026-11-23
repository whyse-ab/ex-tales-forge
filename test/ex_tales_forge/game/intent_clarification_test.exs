defmodule TalesForge.Game.IntentClarificationTest do
  use ExUnit.Case, async: true

  alias TalesForge.Game.IntentClarification, as: Clar
  alias TalesForge.Game.Schemas.{IntentExtraction, SingleAction}

  defp reading(confidence, top2, target \\ nil) do
    %{
      action: List.first(top2),
      target: target,
      confidence: confidence,
      top2: top2,
      extraction: %IntentExtraction{
        overall_intent: "do a thing",
        actions: [%SingleAction{action_type: List.first(top2), target: target}]
      }
    }
  end

  test "class groups actions by consequence" do
    assert Clar.class(:speak) == :talk
    assert Clar.class(:move) == :move
    assert Clar.class(:combat) == :combat
    assert Clar.class(:buy) == :coin
    assert Clar.class(:unknown_thing) == :talk
  end

  test "acts when confident" do
    assert Clar.band(reading(0.85, [:speak, :move])) == :act
  end

  test "clarifies only when unsure and the top two differ in class" do
    assert Clar.band(reading(0.30, [:speak, :move]), ask_below: 0.45) == :clarify
    assert Clar.band(reading(0.30, [:speak, :observe]), ask_below: 0.45) == :best_guess
  end

  test "best guess between act and clarify" do
    assert Clar.band(reading(0.55, [:speak, :move]), ask_below: 0.45) == :best_guess
  end

  describe "raw confidence" do
    defp raw_reading(confidence, raw, top2),
      do: Map.put(reading(confidence, top2), :raw_confidence, raw)

    test "a low raw read clarifies even when calibration lifts it into the act band" do
      # The Lotta case from the 2026-10-09 comparison: raw 0.41 -> 0.815, speak vs move.
      assert Clar.band(raw_reading(0.815, 0.41, [:speak, :move])) == :clarify
    end

    test "a low raw read still plays when the top two are in the same class" do
      assert Clar.band(raw_reading(0.815, 0.41, [:speak, :observe])) == :act
      assert Clar.band(raw_reading(0.60, 0.30, [:speak, :observe])) == :best_guess
    end

    test "a raw read at or above ask_below_raw keeps the calibrated band" do
      assert Clar.band(raw_reading(0.83, 0.45, [:speak, :move])) == :act
      assert Clar.band(raw_reading(0.66, 0.50, [:speak, :move])) == :best_guess
    end

    test "ask_below_raw is configurable and 0.0 turns the raw check off" do
      assert Clar.band(raw_reading(0.815, 0.41, [:speak, :move]), ask_below_raw: 0.0) == :act
      assert Clar.band(raw_reading(0.815, 0.41, [:speak, :move]), ask_below_raw: 0.40) == :act
      assert Clar.band(raw_reading(0.83, 0.43, [:move, :wait]), ask_below_raw: 0.5) == :clarify
    end

    test "a reading without raw_confidence uses the calibrated value only" do
      assert Clar.band(reading(0.815, [:speak, :move])) == :act
    end

    test "defaults are the documented bands" do
      assert Clar.defaults() == Clar.defaults(:v1)

      assert Clar.defaults(:v1) == [
               act_min: 0.70,
               ask_below: 0.45,
               ask_below_raw: 0.45,
               runner_up: 0.25
             ]
    end
  end

  describe "goods and plausible readings (the in-character clarify)" do
    test "moving goods or coins needs act_min; talk does not" do
      assert Clar.band(reading(0.60, [:buy, :buy])) == :clarify
      assert Clar.band(reading(0.60, [:speak, :observe])) == :best_guess
      assert Clar.band(reading(0.75, [:buy, :speak])) == :act
    end

    test "a plausible runner-up of another class clarifies, of the same class does not" do
      rival =
        Map.put(reading(0.9, [:speak, :buy]), :action_probabilities, %{speak: 0.6, buy: 0.3})

      same =
        Map.put(reading(0.9, [:speak, :observe]), :action_probabilities, %{
          speak: 0.6,
          observe: 0.35
        })

      faint = Map.put(rival, :action_probabilities, %{speak: 0.8, buy: 0.2})

      assert Clar.band(rival) == :clarify
      assert Clar.band(same) == :act
      assert Clar.band(faint) == :act
    end
  end

  test "flag off (v1 defaults) equals today's bands and decisions" do
    v1 = Clar.defaults(:v1)
    rival = Map.put(reading(0.9, [:speak, :buy]), :action_probabilities, %{speak: 0.6, buy: 0.3})
    faint = Map.put(rival, :action_probabilities, %{speak: 0.8, buy: 0.2})
    raw = Map.put(reading(0.83, [:speak, :move]), :raw_confidence, 0.35)
    goods = reading(0.75, [:buy, :speak])

    for sample <- [rival, faint, raw, goods, reading(0.85, [:speak, :move])] do
      assert Clar.band(sample) == Clar.band(sample, v1)
    end

    assert Clar.band(rival, v1) == :clarify
    assert Clar.band(faint, v1) == :act
    assert Clar.band(raw, v1) == :clarify
    assert Clar.band(goods, v1) == :act
  end

  test "flag on (v2 defaults) selects the new band set" do
    v2 = Clar.defaults(:v2)

    assert v2 == [
             act_min: 0.80,
             ask_below: 0.45,
             ask_below_raw: 0.30,
             runner_up: 0.40
           ]

    # buy at 0.75 acts today, clarifies under v2 (act_min 0.80)
    goods = reading(0.75, [:buy, :speak])
    assert Clar.band(goods) == :act
    assert Clar.band(goods, v2) == :clarify

    # runner-up 0.30 clarifies today (>= 0.25) and acts under v2 (< 0.40)
    rival = Map.put(reading(0.9, [:speak, :buy]), :action_probabilities, %{speak: 0.6, buy: 0.3})
    assert Clar.band(rival) == :clarify
    assert Clar.band(rival, v2) == :act

    # raw 0.35 clarifies today (< 0.45) and acts under v2 (>= 0.30) when lifted
    raw = Map.put(reading(0.83, [:speak, :move]), :raw_confidence, 0.35)
    assert Clar.band(raw) == :clarify
    assert Clar.band(raw, v2) == :act
  end

  test "candidates are the top two readings as short phrases" do
    assert Clar.candidates(reading(0.30, [:move, :speak], "market_square"), [
             %{label: :c0, kind: :place, id: "market_square", text: "Market Square (exit)"}
           ]) == ["go to Market Square", "talk to them"]
  end
end
