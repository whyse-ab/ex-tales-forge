defmodule TalesForge.NPCRegistryTest do
  use TalesForge.DataCase, async: false

  alias Jido.AgentServer
  alias Jido.Signal
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.NPC
  alias TalesForge.NPCRegistry
  alias TalesForge.NPCSignals
  alias TalesForge.Repo
  alias TalesForge.Schemas.{GameSession, NpcInstance}

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    :ok
  end

  test "create_session starts agent for present NPC at tavern" do
    assert {:ok, session} = GameSessions.create_session(%{name: "NPC Agents"})

    aid = NPCRegistry.agent_id(session.id, "marta_kellen")
    assert Jido.whereis(aid)
  end

  test "sync stops agent when NPC leaves player location" do
    assert {:ok, session} = insert_session_without_scene("NPC Travel")

    :ok = NPCRegistry.sync(session)
    aid = NPCRegistry.agent_id(session.id, "marta_kellen")
    assert Jido.whereis(aid)

    inst = NPC.get_instance(session.id, "marta_kellen")

    inst
    |> NpcInstance.changeset(%{
      runtime_state: Map.put(inst.runtime_state, "location_id", "crossroads_square")
    })
    |> Repo.update!()

    {:ok, _session} = NPC.refresh_session_world_state(session)

    session = GameSessions.get_session!(session.id)
    assert "marta_kellen" not in session.world_state["present_npcs"]

    :ok = NPCRegistry.sync(session.id)
    refute Jido.whereis(aid)
  end

  test "player.talked_to signal appends NPC memory" do
    assert {:ok, session} = GameSessions.create_session(%{name: "NPC Talk"})

    world_tick = Map.get(session.world_state, "world_tick")

    assert {:ok, _agent} =
             deliver_sync(
               session.id,
               "marta_kellen",
               "player.talked_to",
               %{
                 "session_id" => session.id,
                 "npc_id" => "marta_kellen",
                 "player_text" => "Marta, what do you know about the ledger?",
                 "world_tick" => world_tick
               }
             )

    inst = NPC.get_instance(session.id, "marta_kellen")
    [memory | _] = Map.get(inst.runtime_state, "memories", [])

    assert memory["summary"] =~ "ledger"
    assert memory["tick"] == world_tick
  end

  test "world.time.passed escalates concern priority after four ticks" do
    assert {:ok, session} = GameSessions.create_session(%{name: "NPC Time"})

    aid = NPCRegistry.agent_id(session.id, "marta_kellen")
    world_tick = Map.get(session.world_state, "world_tick")

    pid = Jido.whereis(aid)

    signal =
      Signal.new!("world.time.passed", %{"delta_ticks" => 1, "world_tick" => world_tick},
        source: "/test"
      )

    for _ <- 1..4 do
      assert {:ok, _agent} = AgentServer.call(pid, signal)
    end

    inst = NPC.get_instance(session.id, "marta_kellen")
    concern = Map.get(inst.runtime_state, "current_concern")
    assert Map.get(concern, "priority", 0) >= 9
  end

  test "world.time.passed applies string-keyed 288 delta_ticks in one signal" do
    assert {:ok, session} = GameSessions.create_session(%{name: "NPC Wait Concern"})

    aid = NPCRegistry.agent_id(session.id, "marta_kellen")
    pid = Jido.whereis(aid)
    world_tick = Map.get(session.world_state, "world_tick")
    before = NPC.get_instance(session.id, "marta_kellen")
    old_priority = get_in(before.runtime_state, ["current_concern", "priority"])

    signal =
      Signal.new!(
        "world.time.passed",
        %{"delta_ticks" => 288, "world_tick" => world_tick},
        source: "/test"
      )

    assert {:ok, _agent} = AgentServer.call(pid, signal)

    inst = NPC.get_instance(session.id, "marta_kellen")
    concern = Map.get(inst.runtime_state, "current_concern")
    assert Map.get(concern, "priority") == 10
    assert Map.get(concern, "priority") > old_priority
  end

  test "three-day wait escalates pack NPC concern" do
    assert {:ok, session} =
             GameSessions.create_session(%{name: "Tin Valley Wait", adventure_id: "tin_valley"})

    aid = NPCRegistry.agent_id(session.id, "innkeep")
    pid = Jido.whereis(aid)
    assert pid

    before = NPC.get_instance(session.id, "innkeep")
    assert get_in(before.runtime_state, ["current_concern", "focus"]) =~ "armed strangers"
    old_priority = get_in(before.runtime_state, ["current_concern", "priority"])

    signal =
      Signal.new!(
        "world.time.passed",
        %{"delta_ticks" => 288, "world_tick" => Map.get(session.world_state, "world_tick")},
        source: "/test"
      )

    assert {:ok, _agent} = AgentServer.call(pid, signal)

    after_inst = NPC.get_instance(session.id, "innkeep")
    assert get_in(after_inst.runtime_state, ["current_concern", "priority"]) > old_priority
  end

  test "NPCSignals.emit_turn_signals delivers speak handler to target NPC" do
    assert {:ok, session} = GameSessions.create_session(%{name: "NPC Emit"})

    handler = %{
      handler: "speak",
      target: "marta_kellen",
      skill: "persuasion",
      notes: "test"
    }

    :ok = NPCSignals.emit_turn_signals(session.id, session.world_state, handler, "hello marta")

    Process.sleep(100)

    inst = NPC.get_instance(session.id, "marta_kellen")

    assert Enum.any?(Map.get(inst.runtime_state, "memories", []), fn mem ->
             mem["summary"] =~ "hello marta"
           end)

    assert Map.get(inst.runtime_state, "relationship_score", 0.0) > 0.0
  end

  test "NPCSignals treat a dead agent pid as undelivered" do
    pid = spawn(fn -> :ok end)

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    refute Process.alive?(pid)

    signal =
      Signal.new!("world.time.passed", %{"delta_ticks" => 288, "world_tick" => 36},
        source: "/test"
      )

    assert :ok = NPCSignals.call_agent(pid, signal, "session", "ghost", "world.time.passed")
  end

  defp insert_session_without_scene(name) do
    attrs = %{
      name: name,
      status: "active",
      world_state:
        TalesForge.Game.World.default_world_state()
        |> Map.put("last_scene_location", "weary_pilgrim")
    }

    with {:ok, session} <-
           %GameSession{}
           |> GameSession.changeset(attrs)
           |> Repo.insert(),
         :ok <- TalesForge.NPC.seed_session(session),
         {:ok, session} <- TalesForge.NPC.refresh_session_world_state(session) do
      {:ok, session}
    end
  end

  defp deliver_sync(session_id, npc_id, type, payload) do
    aid = NPCRegistry.agent_id(session_id, npc_id)
    signal = Signal.new!(type, payload, source: "/test")

    case Jido.whereis(aid) do
      nil -> {:error, :agent_not_found}
      pid -> AgentServer.call(pid, signal)
    end
  end
end
