defmodule TalesForge.Playtest.GrowthTest do
  use ExUnit.Case, async: true

  alias TalesForge.Playtest.Growth

  doctest Growth

  test "counts failed attempts, ignores turns without a roll and sums per skill" do
    growth =
      Growth.summarize([
        nil,
        %{"outcome" => "none"},
        %{"skill" => "insight", "lp_awarded" => 2.0},
        %{"skill" => "climbing", "lp_awarded" => 1.0},
        %{
          "improvements" => [
            %{"skill" => "insight", "improved" => false, "roll" => 3},
            %{"skill" => "climbing", "improved" => true, "roll" => 9}
          ]
        }
      ])

    assert growth["skills"]["insight"] ==
             %{"rolls" => 1, "lp_gained" => 2.0, "attempts" => 1, "improvements" => 0}

    assert growth["skills"]["climbing"]["improvements"] == 1
    assert %{"rolls" => 2, "lp_gained" => 3.0, "attempts" => 2, "improvements" => 1} = growth
  end

  test "an empty run has zero growth" do
    assert Growth.summarize([]) ==
             %{
               "skills" => %{},
               "rolls" => 0,
               "lp_gained" => 0.0,
               "attempts" => 0,
               "improvements" => 0
             }
  end
end
