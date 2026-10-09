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

  test "asks only when unsure and the top two differ in class" do
    assert Clar.band(reading(0.30, [:speak, :move]), ask_below: 0.45) == :ask
    assert Clar.band(reading(0.30, [:speak, :observe]), ask_below: 0.45) == :best_guess
  end

  test "best guess between act and ask" do
    assert Clar.band(reading(0.55, [:speak, :move]), ask_below: 0.45) == :best_guess
  end

  describe "raw confidence" do
    defp raw_reading(confidence, raw, top2),
      do: Map.put(reading(confidence, top2), :raw_confidence, raw)

    test "a low raw read asks even when calibration lifts it into the act band" do
      # The Lotta case from the 2026-10-09 comparison: raw 0.41 -> 0.815, speak vs move.
      assert Clar.band(raw_reading(0.815, 0.41, [:speak, :move])) == :ask
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
      assert Clar.band(raw_reading(0.83, 0.43, [:move, :wait]), ask_below_raw: 0.5) == :ask
    end

    test "a reading without raw_confidence uses the calibrated value only" do
      assert Clar.band(reading(0.815, [:speak, :move])) == :act
    end

    test "defaults are the documented bands" do
      assert Clar.defaults() == [act_min: 0.70, ask_below: 0.45, ask_below_raw: 0.45]
    end
  end

  test "build produces a clarification payload shaped like Intent.build_clarification" do
    payload =
      Clar.build(reading(0.30, [:move, :speak], "market_square"), [
        %{label: :c0, kind: :place, id: "market_square", text: "Market Square (exit)"}
      ])

    assert is_binary(payload["clarification_id"])
    assert payload["allow_free_text"] == true
    assert String.contains?(payload["question"], "go to")
    assert length(payload["options"]) == 2
    assert Enum.all?(payload["options"], &Map.has_key?(&1, "action_index"))
    assert is_list(payload["actions"])
  end
end
