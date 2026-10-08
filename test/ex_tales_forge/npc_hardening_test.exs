defmodule TalesForge.NPCHardeningTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.NPC
  alias TalesForge.NPCRecovery
  alias TalesForge.NPCRegistry
  alias TalesForge.Repo
  alias TalesForge.Schemas.GameSession

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    :ok
  end

  test "create_session seeds multiple NPC definitions" do
    assert {:ok, session} = GameSessions.create_session(%{name: "Multi NPC"})

    assert NPC.get_instance(session.id, "marta_kellen")
    assert NPC.get_instance(session.id, "worried_merchant")

    assert ["marta_kellen"] = session.world_state["present_npcs"]
    refute "worried_merchant" in session.world_state["present_npcs"]
  end

  test "travel swaps running NPC agents by location" do
    assert {:ok, session} = GameSessions.create_session(%{name: "NPC Travel Swap"})

    marta_aid = NPCRegistry.agent_id(session.id, "marta_kellen")
    henrik_aid = NPCRegistry.agent_id(session.id, "worried_merchant")

    assert Jido.whereis(marta_aid)
    refute Jido.whereis(henrik_aid)

    world_state =
      session.world_state
      |> put_in(["character", "location_id"], "crossroads_square")
      |> Map.put("location_id", "crossroads_square")

    session =
      session
      |> GameSession.changeset(%{world_state: world_state})
      |> Repo.update!()

    {:ok, session} = NPC.refresh_session_world_state(session)
    assert ["worried_merchant"] = session.world_state["present_npcs"]

    :ok = NPCRegistry.sync(session)

    await_agent_gone(marta_aid)
    refute Jido.whereis(marta_aid)
    assert Jido.whereis(henrik_aid)
  end

  test "NPCRecovery restores agents for active sessions" do
    assert {:ok, session} = GameSessions.create_session(%{name: "NPC Recovery"})

    aid = NPCRegistry.agent_id(session.id, "marta_kellen")
    assert Jido.whereis(aid)

    :ok = Jido.stop_agent(aid)
    await_agent_gone(aid)

    assert {:ok, count} = NPCRecovery.recover_now()
    assert count >= 1
    assert Jido.whereis(aid)
  end

  test "the boot sync can be turned off with :npc_recovery_on_boot" do
    on_exit(fn -> Application.delete_env(:ex_tales_forge, :npc_recovery_on_boot) end)

    assert NPCRecovery.boot_sync?()
    Application.put_env(:ex_tales_forge, :npc_recovery_on_boot, false)
    refute NPCRecovery.boot_sync?()
  end

  test "ensure_runtime_started syncs NPC agents on reconnect" do
    assert {:ok, session} = GameSessions.create_session(%{name: "NPC Reconnect"})

    aid = NPCRegistry.agent_id(session.id, "marta_kellen")
    :ok = Jido.stop_agent(aid)
    await_agent_gone(aid)

    session = GameSessions.get_session!(session.id)
    :ok = GameSessions.ensure_runtime_started(session)
    assert Jido.whereis(aid)
  end

  defp await_agent_gone(agent_id) do
    Enum.reduce_while(1..20, :ok, fn _, _ ->
      if is_nil(Jido.whereis(agent_id)),
        do: {:halt, :ok},
        else:
          (
            Process.sleep(5)
            {:cont, :ok}
          )
    end)
  end
end
