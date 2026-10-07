defmodule TalesForge.Game.InnWorldTest do
  @moduledoc """
  INN_WORLD: the places and people around the Valley Inn (tales-forge-docs
  `docs/design-tin-valley-world.md`), loaded as a pack extension for sessions
  created with the flag on.
  """
  use TalesForge.DataCase, async: false

  alias TalesForge.GameSessions
  alias TalesForge.Game.{Features, Pack}
  alias TalesForge.Jido
  alias TalesForge.NPC
  alias TalesForge.Repo
  alias TalesForge.Schemas.GameSession

  doctest TalesForge.Game.Features

  @new_places ~w(herb_cottage inn_yard old_adit smithy west_road)
  @new_people ~w(drover herb_wife smith stable_lad)

  setup do
    previous =
      for key <- ~w(INN_WORLD WORLD_ANTAGONIST), into: %{}, do: {key, System.get_env(key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    System.delete_env("INN_WORLD")
    System.delete_env("WORLD_ANTAGONIST")
    :ok
  end

  describe "Features" do
    test "new sessions take the flags; the baseline variant gets none" do
      assert Features.for_new_session("default") == []

      System.put_env("INN_WORLD", "on")
      assert Features.for_new_session("default") == ["inn_world"]
      assert Features.for_new_session("baseline") == []

      System.put_env("WORLD_ANTAGONIST", "on")
      assert Features.for_new_session("default") == ["inn_world", "antagonist"]

      System.delete_env("INN_WORLD")
      assert Features.for_new_session("default") == [], "the antagonist needs the inn world"
    end

    test "on?/2 reads the session's features" do
      assert Features.on?(%{"features" => ["inn_world"]}, "inn_world")
      refute Features.on?(%{}, "inn_world")
    end
  end

  describe "the pack extension" do
    test "adds five places, joined both ways to the base map" do
      base = Pack.load("tin_valley")
      pack = Pack.load("tin_valley", "default", ["inn_world"])

      assert map_size(base.locations) == 5

      assert pack.locations |> Map.keys() |> Enum.sort() ==
               Enum.sort(Map.keys(base.locations) ++ @new_places)

      for {id, loc} <- pack.locations, exit_id <- loc["exits"] do
        assert id in pack.locations[exit_id]["exits"], "#{exit_id} has no way back to #{id}"
      end

      assert "inn_yard" in pack.locations["valley_inn"]["exits"]
      assert "west_road" in pack.locations["market_square"]["exits"]
    end

    test "adds four people at the new places, each with hooks" do
      pack = Pack.load("tin_valley", "default", ["inn_world"])
      people = Map.new(pack.npcs, &{&1["id"], &1})

      for id <- @new_people do
        assert %{"default_location_id" => loc, "hooks" => [_ | _]} = people[id]
        assert Map.has_key?(pack.locations, loc)
      end
    end

    test "every activity has a hook (trade, crafts, chores, sneak, lore, healing, a bounty)" do
      hooks =
        Pack.load("tin_valley", "default", ["inn_world"]).npcs
        |> Enum.flat_map(&List.wrap(&1["hooks"]))
        |> Enum.join("\n")

      for word <- [
            "sells",
            "bellows",
            "muck out",
            "back ways",
            "old stories",
            "stitches",
            "will pay"
          ] do
        assert hooks =~ word, "no hook mentions #{inspect(word)}"
      end
    end

    test "the baseline variant and sessions without the feature keep the base pack" do
      assert map_size(Pack.load("tin_valley", "baseline", ["inn_world"]).locations) == 5
      assert length(Pack.load("tin_valley").npcs) == 3
    end
  end

  describe "location blurbs" do
    test "are the first paragraph under the heading; the baseline keeps the old reading" do
      assert Pack.load("tin_valley").locations["valley_inn"]["blurb"] =~ "A timber inn"

      assert Pack.load("tin_valley", "baseline").locations["valley_inn"]["blurb"] ==
               "# Valley Inn"
    end
  end

  describe "sessions" do
    test "INN_WORLD=on: the session records the feature and seeds the new people" do
      System.put_env("INN_WORLD", "on")
      {:ok, session} = GameSessions.create_session(%{adventure_id: "tin_valley"})

      assert session.world_state["features"] == ["inn_world"]
      assert Map.has_key?(session.world_state["locations"], "inn_yard")

      npc_ids = session.id |> NPC.list_instances() |> Enum.map(& &1.npc_id) |> Enum.sort()
      assert npc_ids == Enum.sort(~w(guild_steward innkeep prospector) ++ @new_people)
    end

    test "INN_WORLD off: unchanged world_state, three people" do
      {:ok, session} = GameSessions.create_session(%{adventure_id: "tin_valley"})

      refute Map.has_key?(session.world_state, "features")
      assert map_size(session.world_state["locations"]) == 5
      assert length(NPC.list_instances(session.id)) == 3
    end

    test "walking into the yard finds Tam and Mags there, and Brenna stays at the inn" do
      System.put_env("INN_WORLD", "on")
      {:ok, session} = GameSessions.create_session(%{adventure_id: "tin_valley"})

      assert {:ok, _} = GameSessions.submit_message(session.id, "I walk out to the inn yard.")

      world = Repo.get!(GameSession, session.id).world_state
      assert world["location_id"] == "inn_yard"
      assert Enum.sort(world["present_npcs"]) == ["drover", "stable_lad"]
    end
  end
end
