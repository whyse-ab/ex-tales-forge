defmodule TalesForge.Playtest.JevHeadlineTest do
  use ExUnit.Case, async: true

  alias TalesForge.Playtest.JevHeadline

  doctest JevHeadline

  defp row(overall, confidence), do: %{overall: overall, confidence: confidence}

  test "the headline is sum(score × confidence) / sum(confidence) on the 1-5 scale" do
    h = JevHeadline.summarize([row(5.0, 0.9), row(3.0, 0.3), row(1.0, 0.0)])

    assert_in_delta h.score, (5.0 * 0.9 + 3.0 * 0.3) / 1.2, 1.0e-9
    assert h.turns == 3
    assert_in_delta h.unsure_share, 2 / 3, 1.0e-9
  end

  test "the cutoffs: confident from 0.7, high from 3.5, low up to 2.5" do
    h =
      JevHeadline.summarize([
        row(3.5, 0.7),
        row(2.5, 0.7),
        row(3.0, 0.95),
        row(4.9, 0.69)
      ])

    assert %{high: 1, low: 1, middle: 1, unsure: 1, turns: 4} = h
    assert h.unsure_share == 0.25
  end

  test "a turn without confidence is unsure and weightless; a turn without a score is left out" do
    h = JevHeadline.summarize([row(4.0, nil), row(nil, 0.9), row(2.0, 0.8)])

    assert h.score == 2.0
    assert %{turns: 2, unsure: 1, low: 1} = h
  end

  test "no weight at all gives no headline, but still an unsure share" do
    h = JevHeadline.summarize([row(4.0, 0.0), row(3.0, nil)])

    assert h.score == nil
    assert h.unsure_share == 1.0
    assert JevHeadline.format(h) == "— · unsure 100%"
  end

  test "format and breakdown" do
    h = JevHeadline.summarize([row(4.0, 0.8), row(4.5, 0.8), row(2.0, 0.5)])

    assert JevHeadline.format(h) == "3.71/5 · unsure 33%"
    assert JevHeadline.breakdown(h) == "2 high · 0 low · 0 middle · 1 unsure"
    assert JevHeadline.format(%{score: 4.0, unsure_share: nil}) == "4.00/5"
    assert JevHeadline.unsure_below() == 0.7
  end
end
