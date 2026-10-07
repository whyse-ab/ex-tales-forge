defmodule TalesForge.Characters.LeversTest do
  use ExUnit.Case, async: true

  alias TalesForge.Characters.Levers
  alias TalesForge.Game.Pack

  @valid %{"maslow" => "safety", "concerns" => [%{"text" => "Keep the inn", "priority" => 5}]}

  test "accepts valid levers, with OCEAN from ocean or motivations.personality_traits" do
    assert :ok = Levers.validate!(@valid, "t")
    assert :ok = Levers.validate!(Map.put(@valid, "ocean", %{"openness" => 0}), "t")

    npc = Map.put(@valid, "motivations", %{"personality_traits" => %{"neuroticism" => 10}})
    assert :ok = Levers.validate!(npc, "t")
    assert Levers.ocean_source(npc) == %{"neuroticism" => 10}
  end

  test "rejects bad levers and names the source" do
    concern = %{"text" => "c"}

    for {bad, message} <- [
          {Map.delete(@valid, "maslow"), ~r/x\.json: maslow must be one of/},
          {Map.put(@valid, "maslow", "wealth"), ~r/maslow/},
          {Map.delete(@valid, "concerns"), ~r/concerns must be a list/},
          {Map.put(@valid, "concerns", [concern, concern, concern, concern]), ~r/at most 3/},
          {Map.put(@valid, "concerns", [%{"focus" => "f"}]), ~r/non-empty text/},
          {Map.put(@valid, "concerns", [%{"text" => "t", "priority" => 11}]), ~r/priority/},
          {Map.put(@valid, "ocean", %{"openness" => 11}), ~r/OCEAN/},
          {Map.put(@valid, "ocean", %{"charm" => 5}), ~r/OCEAN/}
        ] do
      assert_raise ArgumentError, message, fn -> Levers.validate!(bad, "x.json") end
    end
  end

  describe "every authored file" do
    test "pack NPCs and player characters load with valid levers" do
      pack = Pack.load("tin_valley")
      assert length(pack.npcs) == 3
      assert pack.player_character["id"] == "elara_voss"

      for adventure <- ["crossroads_ledger", "tin_valley"] do
        assert %{"maslow" => _, "concerns" => _, "ocean" => _} = Pack.player_character!(adventure)
      end
    end

    test "the legacy priv/npcs files carry valid levers" do
      dir = Path.join(:code.priv_dir(:ex_tales_forge), "npcs")

      for file <- Path.wildcard(Path.join(dir, "*.json")) do
        assert :ok = file |> File.read!() |> Jason.decode!() |> Levers.validate!(file)
      end
    end
  end

  test "a player character file must have the sheet keys" do
    assert_raise ArgumentError, ~r/needs "stats"/, fn ->
      Pack.validate_player_character!(
        Map.merge(@valid, %{"id" => "a", "name" => "A", "race" => "human"}),
        "pc.json"
      )
    end
  end
end
