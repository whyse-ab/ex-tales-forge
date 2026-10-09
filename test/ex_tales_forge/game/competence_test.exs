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

  describe "default variant: banked LP are resolved on a long rest" do
    test "sleep rolls until the first success, then the skill's LP are gone", %{
      session: session
    } do
      session = seed_lp(session, 3.0)

      {_session, turn, _payload} = wait_sim(session, "I sleep", %{"climbing" => [3, 11, 20]})

      session = reload(session.id)
      assert get_in(session.world_state, ["character", "skills", "climbing"]) == 4
      assert get_in(session.world_state, ["character", "learning_points", "climbing"]) == 0.0

      assert [
               %{"skill" => "climbing", "roll" => 3, "raw_skill" => 3, "improved" => false},
               %{"skill" => "climbing", "roll" => 11, "raw_skill" => 3, "improved" => true}
             ] = turn.mechanical_resolution["improvements"]

      assert Enum.all?(turn.mechanical_resolution["improvements"], &(&1["lp_spent"] == 1))
      assert List.last(turn.mechanical_resolution["improvements"])["lp_cleared"] == 1
    end

    test "a night of failed rolls leaves nothing for the next night", %{session: session} do
      session = seed_lp(session, 2.0)
      {_s, _turn, _p} = wait_sim(session, "I sleep", %{"climbing" => [1, 2]})

      session = reload(session.id)
      assert get_in(session.world_state, ["character", "skills", "climbing"]) == 3
      assert get_in(session.world_state, ["character", "learning_points", "climbing"]) == 0.0

      {_s, again, _p} = wait_sim(session, "I sleep", %{"climbing" => 20})
      assert again.mechanical_resolution["improvements"] == []
    end

    test "an ordinary turn banks the LP and spends nothing", %{session: session} do
      session = seed_lp(session, 3.0)
      {_session, turn, _payload} = observe_sim(session, "study the cliff", %{"climbing" => 20})

      session = reload(session.id)
      assert get_in(session.world_state, ["character", "skills", "climbing"]) == 3
      assert get_in(session.world_state, ["character", "learning_points", "climbing"]) == 3.0
      assert turn.mechanical_resolution["improvements"] == []
    end

    test "a short rest is not a long rest; six hours is", %{session: session} do
      session = seed_lp(session, 1.0)
      {_s, short, _p} = wait_sim(session, "I rest for an hour", %{"climbing" => 20})
      assert short.mechanical_resolution["improvements"] == []

      {_s, long, _p} = wait_sim(reload(session.id), "I rest for six hours", %{"climbing" => 20})
      assert [%{"improved" => true}] = long.mechanical_resolution["improvements"]
    end

    test "the per-run growth log counts the attempts", %{session: session} do
      session = seed_lp(session, 2.0)
      wait_sim(session, "I sleep", %{"climbing" => [3, 11]})

      growth = Growth.for_session(session.id)
      assert growth["attempts"] == 2
      assert growth["improvements"] == 1
      assert growth["skills"]["climbing"]["attempts"] == 2
    end

    test "from level 10 the LP wait for a rest spent reflecting on the skill", %{
      session: session
    } do
      session =
        put_character(session, fn character ->
          character
          |> Map.update("skills", %{"climbing" => 10}, &Map.put(&1, "climbing", 10))
          |> Map.put("learning_points", %{"climbing" => 4.0})
        end)

      {_s, plain, _p} = wait_sim(session, "I sleep", %{"climbing" => 20})
      assert plain.mechanical_resolution["improvements"] == []
      session = reload(session.id)
      assert get_in(session.world_state, ["character", "learning_points", "climbing"]) == 4.0

      # Reflecting the turn before counts, and the rest clears the list.
      {session, _t, _p} = observe_sim(session, "I think over my climbing on that cliff", %{})
      assert get_in(session.world_state, ["character", "reflecting"]) == ["climbing"]

      {_s, rest, _p} = wait_sim(session, "I sleep", %{"climbing" => 20})
      assert [%{"improved" => true, "lp_spent" => 4}] = rest.mechanical_resolution["improvements"]

      session = reload(session.id)
      assert get_in(session.world_state, ["character", "skills", "climbing"]) == 11
      refute Map.has_key?(session.world_state["character"], "reflecting")
    end

    test "an attempt needs at least 11, even at level 0 or 1", %{session: session} do
      session =
        put_character(session, fn character ->
          character
          |> Map.update("skills", %{"tracking" => 0}, &Map.put(&1, "tracking", 0))
          |> Map.put("learning_points", %{"tracking" => 2.0})
        end)

      {_s, turn, _p} = wait_sim(session, "I sleep", %{"tracking" => [10, 11]})

      assert [%{"improved" => false}, %{"improved" => true}] =
               turn.mechanical_resolution["improvements"]

      assert get_in(reload(session.id).world_state, ["character", "skills", "tracking"]) == 1
    end

    test "the dead learn nothing", %{session: session} do
      session =
        session
        |> seed_lp(3.0)
        |> put_character(&Map.put(&1, "vitality", "dead"))

      {_session, turn, _payload} = wait_sim(session, "I sleep", %{"climbing" => 20})

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
