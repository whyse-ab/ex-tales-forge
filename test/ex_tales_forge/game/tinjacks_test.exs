defmodule TalesForge.Game.TinjacksTest do
  @moduledoc """
  WORLD_ANTAGONIST: the Tinjacks act on world time (tales-forge-docs
  `docs/design-tin-valley-world.md`): rumour → incident → road toll at the
  inn → burning; fights against them and talking their lookout round feed
  back into the world. The toll is taken even when the player is out, and then
  Rusk and Cobb come to the player.
  """
  use TalesForge.DataCase, async: false

  alias TalesForge.Fronts
  alias TalesForge.Game.{Events, Pack, WorldSim}
  alias TalesForge.Game.Schemas.{MechanicalResolution, PlayerAction, SingleAction}
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.NPC
  alias TalesForge.Repo
  alias TalesForge.Schemas.GameSession

  @features ["inn_world", "antagonist"]

  setup do
    previous =
      for key <- ~w(INN_WORLD WORLD_ANTAGONIST), into: %{}, do: {key, System.get_env(key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    :ok
  end

  defp pack, do: Pack.load("tin_valley", "default", @features)

  defp front do
    defn = Enum.find(pack().fronts, &(&1["id"] == "tinjacks"))

    %{
      front_id: "tinjacks",
      status: "live",
      definition: defn,
      runtime_state: %{
        "clocks" => defn["clocks"],
        "resources" => defn["resources"],
        "memories" => [],
        "public_facts" => defn["public_facts"]
      }
    }
  end

  defp people do
    for npc <- pack().npcs do
      %{
        npc_id: npc["id"],
        definition: npc,
        runtime_state: %{"location_id" => npc["default_location_id"]}
      }
    end
  end

  defp time_passed(ticks, player_at \\ "valley_inn") do
    %{
      "kind" => "time.passed",
      "actor" => "world",
      "player_aware" => true,
      "location_id" => player_at,
      "payload" => %{"delta_ticks" => ticks}
    }
  end

  defp tick(fronts, people, events) do
    {:ok, sim} = WorldSim.tick(%{fronts: fronts, people: people, events: events})
    {hd(sim.fronts), sim.people}
  end

  defp fact_ids(front), do: Enum.map(front.runtime_state["public_facts"], & &1["id"])

  defp location(people, id),
    do: Enum.find(people, &(&1.npc_id == id)).runtime_state["location_id"]

  describe "on world time" do
    test "a rumour from the start, then the break-in, then the toll at the inn, then the burning" do
      start = front()
      assert fact_ids(start) == ["tinjacks_rumour"]

      {f1, p1} = tick([start], people(), [time_passed(3)])
      assert "tinjacks_watchman" in fact_ids(f1)
      assert location(p1, "rusk") == "old_adit"

      {f2, p2} = tick([f1], p1, [time_passed(3)])
      assert "tinjacks_toll" in fact_ids(f2)
      assert location(p2, "rusk") == "valley_inn"
      assert location(p2, "cobb") == "valley_inn"

      {f3, p3} = tick([f2], p2, [time_passed(6, "market_square")])
      assert "tinjacks_burning" in fact_ids(f3)
      refute "tinjacks_toll" in fact_ids(f3)
      assert location(p3, "rusk") == "old_adit"
    end

    test "a long sleep fires every stage it passes, once" do
      {f, _p} = tick([front()], people(), [time_passed(32, "market_square")])
      assert f.runtime_state["stages_fired"] == ["trouble:3", "trouble:6", "trouble:12"]

      {f2, _} = tick([f], people(), [time_passed(4, "market_square")])
      assert f2.runtime_state["public_facts"] == f.runtime_state["public_facts"]
    end

    test "the gang does not walk off to the inn while the player is at the adit" do
      {f, p} = tick([front()], people(), [time_passed(6, "old_adit")])
      refute "tinjacks_toll" in fact_ids(f)
      refute "tinjacks_toll_taken" in fact_ids(f)
      assert location(p, "rusk") == "old_adit"

      {f2, p2} = tick([f], p, [time_passed(1, "valley_inn")])
      assert "tinjacks_toll" in fact_ids(f2)
      assert location(p2, "rusk") == "valley_inn"
    end
  end

  describe "the toll happens while the player is away" do
    test "the toll is taken at the inn anyway, and Rusk and Cobb come to the player" do
      {f, p} = tick([front()], people(), [time_passed(6, "smithy")])

      assert f.runtime_state["stages_fired"] == ["trouble:3", "trouble:6"]
      refute "tinjacks_toll" in fact_ids(f)
      assert "tinjacks_toll_taken" in fact_ids(f)
      assert "tinjacks_seek" in fact_ids(f)
      assert location(p, "rusk") == "smithy"
      assert location(p, "cobb") == "smithy"

      seek = Enum.find(f.runtime_state["public_facts"], &(&1["id"] == "tinjacks_seek"))
      assert seek["visibility"] == ["smithy"]

      taken = Enum.find(f.runtime_state["public_facts"], &(&1["id"] == "tinjacks_toll_taken"))
      assert "valley_inn" in taken["visibility"] and "herb_cottage" in taken["visibility"]
    end

    test "the people at the inn remember the toll the player missed" do
      {_f, p} = tick([front()], people(), [time_passed(6, "market_square")])

      brenna = Enum.find(p, &(&1.npc_id == "innkeep"))
      assert [%{"who" => "rusk", "felt" => "afraid"}] = brenna.runtime_state["memories"]

      tam = Enum.find(p, &(&1.npc_id == "stable_lad"))
      assert [%{"who" => "cobb", "felt" => "angry"}] = tam.runtime_state["memories"]
    end

    test "they come down the west road to a player who is on it" do
      {f, p} = tick([front()], people(), [time_passed(6, "west_road")])
      assert "tinjacks_seek" in fact_ids(f)
      assert location(p, "rusk") == "west_road"
    end

    test "they do not follow the player into orc country; they wait at the inn" do
      {f, p} = tick([front()], people(), [time_passed(6, "orc_approach")])
      assert "tinjacks_toll_taken" in fact_ids(f)
      assert location(p, "rusk") == "valley_inn"

      seek = Enum.find(f.runtime_state["public_facts"], &(&1["id"] == "tinjacks_seek"))
      assert seek["visibility"] == ["valley_inn"]
    end

    test "at the inn or in the yard the toll is the old confrontation" do
      for here <- ~w(valley_inn inn_yard) do
        {f, p} = tick([front()], people(), [time_passed(6, here)])
        assert "tinjacks_toll" in fact_ids(f)
        refute "tinjacks_toll_taken" in fact_ids(f)
        refute "tinjacks_seek" in fact_ids(f)
        assert location(p, "rusk") == "valley_inn"
      end
    end

    test "the burning sends them home and ends the hunt for the player" do
      {f, p} = tick([front()], people(), [time_passed(6, "market_square")])
      {f2, p2} = tick([f], p, [time_passed(6, "market_square")])

      assert "tinjacks_burning" in fact_ids(f2)
      refute "tinjacks_seek" in fact_ids(f2)
      assert "tinjacks_toll_taken" in fact_ids(f2)
      assert location(p2, "rusk") == "old_adit"
    end
  end

  describe "fights and talk feed back" do
    defp action(type, target \\ nil),
      do: %PlayerAction{
        overall_intent: "x",
        action: %SingleAction{action_type: type, target: target}
      }

    defp events(player_action, outcome, skill, present, loc \\ "valley_inn") do
      world = %{
        "world_tick" => 10,
        "location_id" => loc,
        "character" => %{"location_id" => loc},
        "present_npcs" => present
      }

      mech = %MechanicalResolution{outcome: outcome, skill: skill}

      Events.from_turn(
        player_action,
        %{handler: "skill_check"},
        mech,
        world,
        world,
        [front()],
        people()
      )
    end

    defp kinds(events), do: Enum.map(events, & &1["kind"])

    test "a won fight against Rusk or Cobb hurts the gang, a lost one does not" do
      assert "tinjacks.hurt" in kinds(
               events(action(:combat, "cobb"), "success", "melee_combat", ~w(cobb innkeep rusk))
             )

      assert "tinjacks.won" in kinds(
               events(action(:combat), "failure", "melee_combat", ~w(cobb rusk))
             )

      refute "tinjacks.hurt" in kinds(
               events(action(:combat), "success", "melee_combat", ~w(innkeep))
             )
    end

    test "two won fights break the gang: the front is spent, they are gone, the village remembers" do
      hurt = %{"kind" => "tinjacks.hurt", "location_id" => "valley_inn", "payload" => %{}}
      {f, p} = tick([front()], people(), [time_passed(6), hurt])
      assert f.status == "live"

      {f2, p2} = tick([f], p, [hurt])
      assert f2.status == "spent"
      assert "tinjacks_broken" in fact_ids(f2)
      refute "tinjacks_toll" in fact_ids(f2)
      assert location(p2, "rusk") == "gone"

      brenna = Enum.find(p2, &(&1.npc_id == "innkeep"))
      assert [%{"felt" => "grateful"}] = brenna.runtime_state["memories"]

      {f3, _} = tick([f2], p2, [time_passed(20)])
      assert f3.runtime_state == f2.runtime_state, "a spent front no longer ticks"
    end

    test "talking Pip round sends him home and gives up the hideout" do
      evs = events(action(:speak, "pip"), "success", "persuasion", ["pip"], "west_road")
      assert "tinjacks.lookout_turned" in kinds(evs)

      {f, p} = tick([front()], people(), evs)
      assert "tinjacks_pip_home" in fact_ids(f)
      assert location(p, "pip") == "herb_cottage"
    end

    test "walking into the adit unseen needs a stealth success" do
      before = %{"character" => %{"location_id" => "west_road"}, "world_tick" => 1}

      after_move = %{
        "character" => %{"location_id" => "old_adit"},
        "world_tick" => 2,
        "present_npcs" => []
      }

      mech = %MechanicalResolution{outcome: "none"}

      evs =
        Events.from_turn(
          action(:move, "old_adit"),
          %{handler: "move"},
          mech,
          before,
          after_move,
          [front()],
          []
        )

      assert "tinjacks.spotted" in kinds(evs)
    end
  end

  describe "sessions" do
    test "with both flags the session has the Tinjacks; the toll arrives at the inn during a turn" do
      System.put_env("INN_WORLD", "on")
      System.put_env("WORLD_ANTAGONIST", "on")
      {:ok, session} = GameSessions.create_session(%{adventure_id: "tin_valley"})

      assert session.world_state["features"] == @features
      assert Fronts.get_instance(session.id, "tinjacks")
      assert NPC.get_instance(session.id, "rusk").runtime_state["location_id"] == "old_adit"

      assert {:ok, _} =
               GameSessions.submit_message(session.id, "I wait by the fire for two hours.")

      world = Repo.get!(GameSession, session.id).world_state
      assert world["location_id"] == "valley_inn"
      assert "rusk" in world["present_npcs"] and "cobb" in world["present_npcs"]
      assert Enum.any?(world["public_facts"], &(&1["id"] == "tinjacks_toll"))
      assert NPC.get_instance(session.id, "rusk").runtime_state["location_id"] == "valley_inn"
    end

    test "a player who is out when the toll comes due finds Rusk and Cobb at their side" do
      System.put_env("INN_WORLD", "on")
      System.put_env("WORLD_ANTAGONIST", "on")
      {:ok, session} = GameSessions.create_session(%{adventure_id: "tin_valley"})

      session
      |> Ecto.Changeset.change(
        world_state:
          session.world_state
          |> Map.merge(%{"location_id" => "smithy", "last_scene_location" => "smithy"})
          |> put_in(["character", "location_id"], "smithy")
      )
      |> Repo.update!()

      assert {:ok, _} =
               GameSessions.submit_message(session.id, "I wait by the forge for two hours.")

      world = Repo.get!(GameSession, session.id).world_state
      assert world["location_id"] == "smithy"
      assert "rusk" in world["present_npcs"] and "cobb" in world["present_npcs"]

      ids = Enum.map(world["public_facts"], & &1["id"])
      assert "tinjacks_seek" in ids and "tinjacks_toll_taken" in ids
      refute "tinjacks_toll" in ids

      memories = NPC.get_instance(session.id, "innkeep").runtime_state["memories"]
      assert Enum.any?(memories, &(&1["who"] == "rusk"))
    end

    test "WORLD_ANTAGONIST alone does nothing; without flags there is no Tinjacks front" do
      System.delete_env("INN_WORLD")
      System.put_env("WORLD_ANTAGONIST", "on")
      {:ok, session} = GameSessions.create_session(%{adventure_id: "tin_valley"})

      refute Map.has_key?(session.world_state, "features")
      refute Fronts.get_instance(session.id, "tinjacks")
      refute NPC.get_instance(session.id, "rusk")
    end
  end
end
