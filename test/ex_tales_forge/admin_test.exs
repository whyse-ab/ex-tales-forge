defmodule TalesForge.AdminTest do
  use TalesForge.DataCase, async: false

  import Ecto.Query

  alias TalesForge.Admin
  alias TalesForge.GameSessions
  alias TalesForge.Repo
  alias TalesForge.Schemas.{AICall, FrontInstance, GameSession, NpcInstance, SessionEvent}

  test "stats returns counts" do
    before = Admin.stats()
    {:ok, session} = GameSessions.create_session(%{name: "Stats Test"})
    {:ok, _} = Admin.update_session(session, %{status: "paused"})
    {:ok, _} = GameSessions.create_session(%{name: "Stats Test 2"})
    stats = Admin.stats()

    assert stats.sessions == before.sessions + 2
    assert stats.active_sessions == before.active_sessions + 1
    assert stats.npc_instances > before.npc_instances
    assert is_integer(stats.turns)
    assert is_integer(stats.scenes)
  end

  test "list_sessions is newest first" do
    {:ok, older} = GameSessions.create_session(%{name: "Older"})

    Repo.update_all(from(s in GameSession, where: s.id == ^older.id),
      set: [inserted_at: ~U[2020-01-01 00:00:00Z]]
    )

    {:ok, newer} = GameSessions.create_session(%{name: "Newer"})

    ids = Enum.map(Admin.list_sessions(), & &1.session.id)
    assert Enum.find_index(ids, &(&1 == newer.id)) < Enum.find_index(ids, &(&1 == older.id))
  end

  test "list_sessions includes turn count" do
    {:ok, session} = GameSessions.create_session(%{name: "List Test"})

    assert [%{session: %{id: id}, turn_count: 0}] =
             Enum.filter(Admin.list_sessions(), &(&1.session.id == session.id))

    assert id == session.id
  end

  test "update_session_world_state validates json" do
    {:ok, session} = GameSessions.create_session(%{name: "JSON Test"})
    assert {:error, _} = Admin.update_session_world_state(session, "not json")
    assert {:ok, updated} = Admin.update_session_world_state(session, ~s({"location_id": "test"}))
    assert updated.world_state["location_id"] == "test"
  end

  test "delete_session cascades turns and npc instances" do
    {:ok, session} = GameSessions.create_session(%{name: "Delete Test"})
    assert length(Admin.list_npc_instances(session.id)) > 0
    assert :ok = Admin.delete_session(session)
    refute Repo.get(TalesForge.Schemas.GameSession, session.id)
    assert Admin.list_turns(session.id) == []
    assert Repo.all(from n in NpcInstance, where: n.game_session_id == ^session.id) == []
  end

  test "delete_session removes child rows and keeps ai_calls with a NULL session" do
    {:ok, session} = GameSessions.create_session(%{name: "Cascade Test"})

    Repo.insert!(
      SessionEvent.changeset(%SessionEvent{}, %{
        game_session_id: session.id,
        kind: "test",
        tick: 1
      })
    )

    call =
      Repo.insert!(
        AICall.changeset(%AICall{}, %{
          game_session_id: session.id,
          purpose: "test",
          model: "test-model",
          status: "ok",
          latency_ms: 1,
          call_type: "llm"
        })
      )

    assert :ok = Admin.delete_session(session)

    for schema <- [NpcInstance, SessionEvent, FrontInstance] do
      assert Repo.all(from r in schema, where: r.game_session_id == ^session.id) == []
    end

    assert %AICall{game_session_id: nil} = Repo.get!(AICall, call.id)
  end

  test "delete_session on an already deleted session is a no-op" do
    {:ok, session} = GameSessions.create_session(%{name: "Gone Test"})
    assert :ok = Admin.delete_session(session)
    assert :ok = Admin.delete_session(session)
  end

  test "the admin NPC changeset only changes personality, runtime state and disposition" do
    {:ok, session} = GameSessions.create_session(%{name: "NPC Form Test"})
    [npc | _] = Admin.list_npc_instances(session.id)

    assert {:ok, saved} =
             Admin.save_npc_instance(npc, %{
               "disposition" => "0.5",
               "npc_id" => "renamed",
               "game_session_id" => Ecto.UUID.generate()
             })

    assert saved.disposition == 0.5
    assert saved.npc_id == npc.npc_id
    assert saved.game_session_id == session.id

    assert {:error, changeset} = Admin.save_npc_instance(npc, %{"disposition" => "lots"})
    assert %{disposition: [_ | _]} = errors_on(changeset)
  end

  test "get_npc_instance returns nil for an unknown slug" do
    {:ok, session} = GameSessions.create_session(%{name: "NPC Lookup Test"})
    [npc | _] = Admin.list_npc_instances(session.id)
    assert Admin.get_npc_instance(session.id, npc.npc_id).id == npc.id
    assert Admin.get_npc_instance(session.id, "no_such_npc") == nil
  end

  test "reset_session_npcs reseeds instances" do
    {:ok, session} = GameSessions.create_session(%{name: "Reseed Test"})
    [npc | _] = Admin.list_npc_instances(session.id)

    {:ok, _} =
      Admin.update_npc_instance(npc, %{
        runtime_state: Map.put(npc.runtime_state, "mood", "broken")
      })

    assert {:ok, _} = Admin.reset_session_npcs(session)
    refreshed = Admin.get_npc_instance!(session.id, npc.npc_id)
    assert Map.get(refreshed.runtime_state, "mood") != "broken"
  end

  test "npc definitions are read from the pack files" do
    [summary | _] = Admin.list_npc_definitions()
    assert summary.file == "#{summary.id}.json"

    json = Admin.npc_definition_json(summary.id)
    assert json =~ summary.id
    assert Admin.get_npc_definition!(summary.id)["id"] == summary.id

    refute function_exported?(Admin, :save_npc_definition, 2)
  end

  test "get_npc_definition! rejects unknown ids and paths" do
    assert_raise ArgumentError, fn -> Admin.get_npc_definition!("no_such_npc") end
    assert_raise ArgumentError, fn -> Admin.get_npc_definition!("../npcs/marta_kellen") end
  end
end
