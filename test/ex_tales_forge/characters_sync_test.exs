defmodule TalesForge.CharactersSyncTest do
  use TalesForge.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias TalesForge.Characters
  alias TalesForge.Game.{ActionHandler, Intent, TurnProcessor}
  alias TalesForge.Game.Schemas.MechanicalResolution
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.NPC
  alias TalesForge.Repo
  alias TalesForge.Schemas.{Character, CharacterMemory, GameSession, NpcInstance, PlaytestRun}

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    {:ok, session} = GameSessions.create_session(%{name: "Sync", adventure_id: "tin_valley"})
    %{session: session}
  end

  defp reload(id), do: GameSessions.get_session!(id)

  defp wait_turn(session, rolls) do
    {bundle, _} =
      Intent.resolve_bundle("I rest for an hour", %{"exits" => [], "present_npcs" => []})

    action = Intent.validate_player_action(bundle, %{})

    {:ok, _} =
      TurnProcessor.simulate!(
        session,
        "I rest for an hour",
        action,
        ActionHandler.resolve(action),
        %MechanicalResolution{outcome: "none"},
        improvement_rolls: rolls
      )

    reload(session.id)
  end

  defp put_character(session, fun) do
    world = Map.update!(session.world_state, "character", fun)
    session |> GameSession.changeset(%{world_state: world}) |> Repo.update!()
  end

  describe "double-write after a turn" do
    test "the player character and NPC state reach the characters rows", %{session: session} do
      session =
        put_character(session, fn c ->
          c
          |> Map.update!("skills", &Map.put(&1, "climbing", 3))
          |> Map.put("learning_points", %{"climbing" => 5.0})
          |> Map.put("learning_failures", %{"climbing" => 3})
        end)

      NPC.record_memory(session.id, "innkeep", "The stranger paid in silver", 30)
      NPC.bump_relationship(session.id, "innkeep", 0.4)

      session = wait_turn(session, %{"climbing" => 4})
      assert get_in(session.world_state, ["character", "skills", "climbing"]) == 4

      elara = Characters.get_by_slug(session.id, "elara_voss")
      assert elara.skills["climbing"] == 4
      assert elara.learning_points == %{"climbing" => 0}
      # Levers set at seeding are not overwritten by the mirror.
      assert elara.maslow_level == "esteem"
      assert elara.controller == "player"

      innkeep = Characters.get_by_slug(session.id, "innkeep")
      assert_in_delta innkeep.relationships["elara_voss"], 0.4, 0.001

      assert [%{text: "The stranger paid in silver", tick: 30, kind: "memory"}] =
               Characters.list_memories(innkeep)

      # A second turn adds nothing twice.
      wait_turn(reload(session.id), %{})
      assert length(Characters.list_memories(innkeep)) == 1
    end

    test "a failing mirror never fails the turn", %{session: session} do
      broken = %{
        session
        | world_state:
            Map.put(session.world_state, "character", %{"id" => "elara_voss", "name" => nil})
      }

      log = capture_log(fn -> assert :ok = Characters.mirror(broken) end)
      assert log =~ "characters mirror failed"
      assert Characters.get_by_slug(session.id, "elara_voss").name == "Elara Voss"
    end
  end

  describe "backfill/0" do
    test "writes rows for sessions from before characters, idempotently", %{session: session} do
      # A session as it looked before #48: no characters, legacy NPC definitions.
      Repo.delete_all(from c in Character, where: c.game_session_id == ^session.id)

      inst = NPC.get_instance(session.id, "prospector")

      inst
      |> NpcInstance.changeset(%{
        personality: Map.drop(inst.personality, ~w(maslow concerns derive stats)),
        runtime_state:
          inst.runtime_state
          |> Map.put("current_concern", %{"focus" => "orcs on the hill", "priority" => 12})
          |> Map.put("memories", [
            %{"summary" => "Saw lights below", "tick" => 5},
            %{"what" => ""}
          ])
      })
      |> Repo.update!()

      put_character(session, fn c ->
        Map.put(c, "inventory", [
          %{"name" => "Rope Coil", "quantity" => "2"},
          %{"id" => "nameless"}
        ])
      end)

      Repo.insert!(
        PlaytestRun.changeset(%PlaytestRun{}, %{
          game_session_id: session.id,
          persona: "ronny",
          module: "tin_valley",
          turn_limit: 5,
          status: "finished",
          started_at: DateTime.utc_now(:second)
        })
      )

      first = Characters.backfill()
      assert first.failed == []
      assert first.inserted == 4

      elara = Characters.get_by_slug(session.id, "elara_voss")
      assert {elara.controller, elara.controller_ref} == {"bot", "ronny"}
      assert [%{id: "rope_coil", name: "Rope Coil", quantity: 2}] = elara.inventory

      prospector = Characters.get_by_slug(session.id, "prospector")
      assert prospector.maslow_level == "safety"
      assert [%{text: "orcs on the hill", priority: 10}] = prospector.concerns
      assert [%{text: "Saw lights below", tick: 5}] = Characters.list_memories(prospector)

      second = Characters.backfill()
      assert second.failed == []
      assert second.inserted == 0
      assert second.characters == first.characters
      assert second.memories == first.memories
      assert Repo.aggregate(from(m in CharacterMemory), :count) == first.memories
    end

    test "seeding and backfill agree on a fresh session", %{session: session} do
      before =
        Characters.list_for_session(session.id)
        |> Enum.map(&Map.take(&1, [:slug, :controller, :skills, :maslow_level]))

      assert Characters.backfill().failed == []

      after_ =
        Characters.list_for_session(session.id)
        |> Enum.map(&Map.take(&1, [:slug, :controller, :skills, :maslow_level]))

      assert before == after_
    end

    test "mix characters.backfill prints the counts", %{session: session} do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      Mix.Tasks.Characters.Backfill.run([])

      assert_received {:mix_shell, :info, [output]}
      assert output =~ "inserted: 0"
      assert output =~ "failed: []"
      assert Repo.aggregate(where(Character, game_session_id: ^session.id), :count) == 4
    end
  end
end
