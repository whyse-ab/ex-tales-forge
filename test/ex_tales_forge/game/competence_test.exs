defmodule TalesForge.Game.CompetenceTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.Game.ActionHandler
  alias TalesForge.Game.Context
  alias TalesForge.Game.Intent
  alias TalesForge.Game.Prompts
  alias TalesForge.Game.Schemas.{MechanicalResolution, PlayerAction}
  alias TalesForge.Game.TurnProcessor
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.Playtest.Growth
  alias TalesForge.Repo
  alias TalesForge.Schemas.{GameSession, SessionEvent, Turn}

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    {:ok, session} =
      GameSessions.create_session(%{name: "LP Competence", adventure_id: "tin_valley"})

    %{session: session}
  end

  describe "default variant: 1 LP buys one attempt at the end of the turn" do
    test "a turn spends every whole LP and audits each attempt", %{session: session} do
      session = seed_lp(session, 2.0)

      {_session, turn, _payload} =
        observe_sim(session, "study the cliff", %{"climbing" => [4, 3]})

      session = reload(session.id)
      assert get_in(session.world_state, ["character", "skills", "climbing"]) == 4
      assert get_in(session.world_state, ["character", "learning_points", "climbing"]) == 0.0

      assert [
               %{"skill" => "climbing", "roll" => 4, "raw_skill" => 3, "improved" => true},
               %{"skill" => "climbing", "roll" => 3, "raw_skill" => 4, "improved" => false}
             ] = turn.mechanical_resolution["improvements"]

      assert Enum.all?(turn.mechanical_resolution["improvements"], &(&1["lp_spent"] == 1))
    end

    test "the per-run growth log counts the attempts", %{session: session} do
      session = seed_lp(session, 2.5)
      observe_sim(session, "study the cliff", %{"climbing" => [4, 3]})

      growth = Growth.for_session(session.id)
      assert growth["attempts"] == 2
      assert growth["improvements"] == 1
      assert growth["skills"]["climbing"]["attempts"] == 2

      assert get_in(reload(session.id).world_state, ["character", "learning_points", "climbing"]) ==
               0.5
    end

    test "a fraction of an LP waits for the next roll", %{session: session} do
      session = seed_lp(session, 0.5)
      {_session, turn, _payload} = observe_sim(session, "study the cliff", %{"climbing" => 20})

      session = reload(session.id)
      assert get_in(session.world_state, ["character", "skills", "climbing"]) == 3
      assert get_in(session.world_state, ["character", "learning_points", "climbing"]) == 0.5
      assert turn.mechanical_resolution["improvements"] == []
    end

    test "no rest, failure count or threshold is needed", %{session: session} do
      session =
        session
        |> seed_lp(1.0)
        |> put_character(&Map.put(&1, "learning_failures", %{}))

      {_session, turn, _payload} = observe_sim(session, "study the cliff", %{"climbing" => 3})

      assert [%{"improved" => true}] = turn.mechanical_resolution["improvements"]
    end

    test "resting adds no attempts beyond the LP", %{session: session} do
      session = seed_lp(session, 1.0)

      {_session, turn, _payload} =
        wait_sim(session, "I spend three days drinking and gambling at the inn", %{
          "climbing" => 4
        })

      session = reload(session.id)
      assert get_in(session.world_state, ["character", "skills", "climbing"]) == 4
      assert length(turn.mechanical_resolution["improvements"]) == 1
    end

    test "the dead learn nothing", %{session: session} do
      session =
        session
        |> seed_lp(3.0)
        |> put_character(&Map.put(&1, "vitality", "dead"))

      {_session, turn, _payload} = observe_sim(session, "study the cliff", %{"climbing" => 20})

      session = reload(session.id)
      assert get_in(session.world_state, ["character", "skills", "climbing"]) == 3
      assert get_in(session.world_state, ["character", "learning_points", "climbing"]) == 3.0
      assert turn.mechanical_resolution["improvements"] == []
    end
  end

  describe "baseline variant keeps the #64 rule" do
    setup do
      {:ok, session} =
        GameSessions.create_session(%{
          name: "LP Competence baseline",
          adventure_id: "tin_valley",
          variant: "baseline"
        })

      %{session: seed_eligible(session)}
    end

    test "wait one hour with injected success raises climbing and audits the turn", %{
      session: session
    } do
      {_session, turn, _payload} = wait_sim(session, "I rest for an hour", %{"climbing" => 4})

      session = reload(session.id)
      assert get_in(session.world_state, ["character", "skills", "climbing"]) == 4
      assert get_in(session.world_state, ["character", "learning_points", "climbing"]) == 0
      assert get_in(session.world_state, ["character", "learning_failures", "climbing"]) == 0

      assert [
               %{
                 "skill" => "climbing",
                 "roll" => 4,
                 "raw_skill" => 3,
                 "improved" => true
               }
             ] = turn.mechanical_resolution["improvements"]
    end

    test "wait one hour with injected miss leaves skill and sets LP 1.0", %{session: session} do
      {_session, turn, _payload} = wait_sim(session, "I rest for an hour", %{"climbing" => 3})

      session = reload(session.id)
      assert get_in(session.world_state, ["character", "skills", "climbing"]) == 3
      assert get_in(session.world_state, ["character", "learning_points", "climbing"]) == 1.0
      assert get_in(session.world_state, ["character", "learning_failures", "climbing"]) == 0

      assert [%{"skill" => "climbing", "improved" => false, "roll" => 3}] =
               turn.mechanical_resolution["improvements"]
    end

    test "wait 15 minutes does not attempt improvements", %{session: session} do
      before = session.world_state["character"]

      player_action =
        PlayerAction.decode(%{
          "overall_intent" => "wait a moment",
          "action" => %{
            "action_type" => "wait",
            "target" => nil,
            "parameters" => %{"ticks" => 1}
          }
        })

      handler = ActionHandler.resolve(player_action)

      {:ok, _} =
        TurnProcessor.simulate!(
          session,
          "wait a moment",
          player_action,
          handler,
          %MechanicalResolution{outcome: "none"},
          improvement_rolls: %{"climbing" => 20}
        )

      session = reload(session.id)
      turn = latest_turn(session.id)
      assert session.world_state["character"]["skills"] == before["skills"]
      assert session.world_state["character"]["learning_points"] == before["learning_points"]
      assert session.world_state["character"]["learning_failures"] == before["learning_failures"]
      assert turn.mechanical_resolution["improvements"] == []
    end

    test "ordinary skill turn does not improve even when bars are full", %{session: session} do
      before = session.world_state["character"]

      {_session, turn, _payload} =
        observe_sim(session, "study the cliff", %{"climbing" => 20})

      session = reload(session.id)

      assert get_in(session.world_state, ["character", "skills", "climbing"]) ==
               get_in(before, ["skills", "climbing"])

      assert turn.mechanical_resolution["improvements"] == []
    end

    test "wait three days still attempts each skill once", %{session: session} do
      {_session, turn, _payload} =
        wait_sim(session, "I spend three days drinking and gambling at the inn", %{
          "climbing" => 4
        })

      session = reload(session.id)
      assert get_in(session.world_state, ["character", "skills", "climbing"]) == 4
      assert length(turn.mechanical_resolution["improvements"]) == 1
    end
  end

  test "wait does not emit player.improved", %{session: session} do
    session = seed_eligible(session)
    wait_sim(session, "I sleep", %{"climbing" => 4})

    kinds =
      SessionEvent
      |> where([e], e.game_session_id == ^session.id)
      |> select([e], e.kind)
      |> Repo.all()

    refute "player.improved" in kinds
  end

  test "mechanical_bounds stay silent about improvements", %{session: session} do
    session = seed_eligible(session)
    {_session, _turn, payload} = wait_sim(session, "I rest for an hour", %{"climbing" => 4})

    bounds =
      payload.mechanical_resolution
      |> MechanicalResolution.decode()
      |> Context.mechanical_bounds()

    refute bounds =~ "improv"
    refute bounds =~ "+1"
    refute bounds =~ "learned"
  end

  test "gm_system forbids skill patches and learned/XP/level narration" do
    gm = Prompts.gm_system()
    assert gm =~ "skills"
    assert gm =~ "learning_failures"
    assert gm =~ "you learned"
    assert gm =~ "XP"
    assert gm =~ "level"
  end

  defp seed_lp(session, lp) do
    put_character(session, fn character ->
      character
      |> Map.update("skills", %{"climbing" => 3}, &Map.put(&1, "climbing", 3))
      |> Map.put("learning_points", %{"climbing" => lp})
    end)
  end

  defp put_character(session, fun) do
    world = Map.update!(session.world_state, "character", fun)

    session
    |> GameSession.changeset(%{world_state: world})
    |> Repo.update!()
  end

  defp observe_sim(session, raw, rolls) do
    player_action =
      PlayerAction.decode(%{
        "overall_intent" => raw,
        "action" => %{
          "action_type" => "observe",
          "target" => nil,
          "parameters" => %{"skill" => "climbing"}
        }
      })

    {:ok, payload} =
      TurnProcessor.simulate!(
        session,
        raw,
        player_action,
        ActionHandler.resolve(player_action),
        %MechanicalResolution{outcome: "none"},
        improvement_rolls: rolls
      )

    {reload(session.id), latest_turn(session.id), payload}
  end

  defp seed_eligible(session) do
    character = session.world_state["character"]

    character =
      character
      |> Map.update("skills", %{"climbing" => 3}, &Map.put(&1, "climbing", 3))
      |> Map.put("learning_points", %{"climbing" => 5.0})
      |> Map.put("learning_failures", %{"climbing" => 3})

    world = put_in(session.world_state, ["character"], character)

    session
    |> GameSession.changeset(%{world_state: world})
    |> Repo.update!()
  end

  defp wait_sim(session, raw, rolls) do
    player_action = wait_action(raw)
    handler = ActionHandler.resolve(player_action)

    {:ok, payload} =
      TurnProcessor.simulate!(
        session,
        raw,
        player_action,
        handler,
        %MechanicalResolution{outcome: "none"},
        improvement_rolls: rolls
      )

    {reload(session.id), latest_turn(session.id), payload}
  end

  defp wait_action(raw) do
    {bundle, _} = Intent.resolve_bundle(raw, %{"exits" => [], "present_npcs" => []})
    Intent.validate_player_action(bundle, %{})
  end

  defp latest_turn(session_id) do
    Turn
    |> where([t], t.game_session_id == ^session_id)
    |> order_by([t], desc: t.turn_number)
    |> limit(1)
    |> Repo.one!()
  end

  defp reload(id), do: GameSessions.get_session!(id)
end
