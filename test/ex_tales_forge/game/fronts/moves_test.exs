defmodule TalesForge.Game.Fronts.MovesTest do
  @moduledoc """
  Pack moves that come to the player: `"@player"` in `move_people` and in a
  fact's `visibility`, with `player_out_of_reach` and `player_fallback`.
  """
  use ExUnit.Case, async: true

  alias TalesForge.Game.Fronts.Moves

  doctest Moves

  @defn %{
    "moves" => %{
      "come" => %{
        "move_people" => %{"rusk" => "@player", "pip" => "west_road"},
        "player_out_of_reach" => ["orc_nest"],
        "public_facts" => [
          %{"id" => "here", "text" => "They are here.", "visibility" => ["@player"]},
          %{"id" => "inn", "text" => "Talk at the inn.", "visibility" => ["valley_inn"]}
        ]
      }
    }
  }

  test "@player becomes the player's place in moves and facts" do
    {:ok, state} = Moves.apply(%{}, "come", @defn, player_at: "smithy")

    assert state["pending"]["move_people"] == %{"rusk" => "smithy", "pip" => "west_road"}

    assert [%{"id" => "here", "visibility" => ["smithy"]}, %{"id" => "inn"}] =
             state["public_facts"]
  end

  test "without a fallback, an out-of-reach player drops the @player entries" do
    {:ok, state} = Moves.apply(%{}, "come", @defn, player_at: "orc_nest")

    assert state["pending"]["move_people"] == %{"pip" => "west_road"}
    assert [%{"id" => "here", "visibility" => []}, %{"id" => "inn"}] = state["public_facts"]
  end

  test "moves without @player are unchanged by the player's place" do
    defn = %{"moves" => %{"go" => %{"move_people" => %{"cobb" => "old_adit"}}}}

    assert Moves.apply(%{}, "go", defn, player_at: "smithy") == Moves.apply(%{}, "go", defn)
  end
end
