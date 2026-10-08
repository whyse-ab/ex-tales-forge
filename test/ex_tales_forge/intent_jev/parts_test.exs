defmodule TalesForge.IntentJev.PartsTest do
  @moduledoc "The pure parts of Jev intent: quote, calibration, cache key, run flags."
  use ExUnit.Case, async: true

  alias TalesForge.Game.{IntentCalibration, JevIntent, PlayerQuote}
  alias TalesForge.Game.Schemas.{PlayerAction, SingleAction}
  alias TalesForge.IntentEval.{Calibration, Readers}
  alias TalesForge.Playtest.RunMeta

  doctest PlayerQuote
  doctest IntentCalibration
  doctest TalesForge.Game.Intent, only: [sanitize_quote: 1]

  @action %PlayerAction{
    overall_intent: "x",
    action: %SingleAction{action_type: :speak, target: "innkeep"}
  }

  describe "PlayerQuote.decide/5" do
    test "a confident benign read quotes the player's sanitised words" do
      q = PlayerQuote.decide(@action, "  Hello   there ", safety(:benign, 0.95), 0.9)
      assert {q.quote, q.used, q.reason} == {"Hello there", "quote", "benign"}
    end

    test "anything else gets the typed summary" do
      summary = "speak (target: innkeep)"

      assert %{quote: ^summary, reason: "low_confidence"} =
               PlayerQuote.decide(@action, "Hello", safety(:benign, 0.8), 0.9)

      assert %{quote: ^summary, reason: "label_prompt_injection"} =
               PlayerQuote.decide(@action, "Hello", safety(:prompt_injection, 0.99), 0.9)

      assert %{quote: ^summary, reason: "jev_timeout"} =
               PlayerQuote.decide(@action, "Hello", nil, 0.9, "jev_timeout")

      assert %{quote: ^summary, reason: "empty_text"} =
               PlayerQuote.decide(@action, "   ", safety(:benign, 0.99), 0.9)
    end

    test "only nefarious is declined, and meta leaves out the text" do
      assert PlayerQuote.decline?(safety(:nefarious, 0.6))
      refute PlayerQuote.decline?(safety(:jailbreak, 0.99))
      refute PlayerQuote.decline?(nil)

      meta =
        @action
        |> PlayerQuote.decide("secret words", safety(:benign, 0.99), 0.9)
        |> PlayerQuote.meta()

      refute inspect(meta) =~ "secret words"
      assert meta["used"] == "quote"
    end

    defp safety(label, c), do: %{label: label, confidence: c, benign_probability: 0.5}
  end

  describe "Calibration" do
    test "fit is monotonic, pinned at chance for raw 0, and never claims certainty" do
      points =
        for i <- 1..200 do
          x = i / 200
          {x, :erlang.phash2(i, 100) < 60 + 40 * x}
        end

      %{"points" => knots} = Calibration.fit(points, min_block: 15)
      ys = Enum.map(knots, &List.last/1)
      assert hd(knots) == [0.0, 0.0625]
      assert List.last(knots) |> hd() == 1.0
      assert ys == Enum.sort(ys)
      assert Enum.all?(ys, &(&1 < 1.0))
    end

    test "ece is zero when confidence matches accuracy and nil for no points" do
      assert Calibration.ece([{0.95, true}, {0.95, true}, {0.05, false}]) < 0.06
      assert Calibration.ece([]) == nil
    end

    test "fit_scored fits on the Jev readings' raw confidence and reports CV ECE" do
      scored =
        for i <- 1..60 do
          right? = rem(i, 10) != 0

          %{
            item: %{"id" => "i#{i}", "gold" => %{"action" => "speak"}},
            readings: %{
              jev: %{
                status: :ok,
                action: if(right?, do: :speak, else: :move),
                raw_confidence: i / 60
              }
            }
          }
        end

      {map, stats} = Calibration.fit_scored(scored, version: "test-v1")
      assert map["version"] == "test-v1"
      assert map["fitted_on"] == "tune"
      assert map["n"] == 60 and stats.n == 60
      assert is_float(stats.cv_ece) and is_float(stats.in_sample_ece)
    end

    test "the compiled map is the committed tune fit" do
      assert IntentCalibration.version() =~ "jev-intent-cal-"
      assert IntentCalibration.apply(0.0) == 0.0625
      assert IntentCalibration.apply(0.95) > IntentCalibration.apply(0.5)
    end
  end

  describe "Readers.request_key/3" do
    test "does not depend on map key order and changes with the request" do
      context = %{"location_id" => "inn", "present_npcs" => [], "exits" => ["square"]}
      cands = JevIntent.candidates(context)
      state = JevIntent.state(context, "go to the square")
      reordered = state |> Enum.reverse() |> Map.new()

      key = Readers.request_key(state, JevIntent.questions(cands), "jev-1.13.0")
      assert key == Readers.request_key(reordered, JevIntent.questions(cands), "jev-1.13.0")
      refute key == Readers.request_key(state, JevIntent.questions(cands), "jev-other")

      refute key ==
               Readers.request_key(
                 JevIntent.state(context, "wait"),
                 JevIntent.questions(cands),
                 "jev-1.13.0"
               )
    end
  end

  test "run flags carry the session's intent mode" do
    assert RunMeta.flags("paul", %{"intent_jev" => "shadow"})["intent_jev"] == "shadow"
    assert RunMeta.flags("paul")["intent_jev"] == "off"
  end
end
