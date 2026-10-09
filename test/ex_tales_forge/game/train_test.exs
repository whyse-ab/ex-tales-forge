defmodule TalesForge.Game.TrainTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.Game.ActionHandler
  alias TalesForge.Game.Context
  alias TalesForge.Game.Intent
  alias TalesForge.Game.Inventory
  alias TalesForge.Game.Schemas.{MechanicalResolution, PlayerAction, SingleAction}
  alias TalesForge.Game.Train
  alias TalesForge.Game.TurnProcessor
  alias TalesForge.Game.WorldClock
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.Repo
  alias TalesForge.Schemas.{GameSession, SessionEvent, Turn}

  @inn_context %{
    "exits" => ["market_square"],
    "exit_names" => %{"market_square" => "Market Square"},
    "present_npcs" => ["innkeep"],
    "npc_details" => %{"innkeep" => %{"name" => "Brenna Holt", "role" => "innkeep"}}
  }

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    {:ok, session} =
      GameSessions.create_session(%{name: "Trainers", adventure_id: "tin_valley"})

    %{session: session}
  end

  test "heuristic trains persuasion with Brenna for a day" do
    {bundle, _} = Intent.resolve_bundle("I train persuasion with Brenna for a day", @inn_context)
    action = hd(bundle.actions)

    assert action.action_type == :train
    assert action.target == "innkeep"
    assert action.parameters["skill"] == "persuasion"
    assert action.parameters["ticks"] == 96
  end

  test "spend three days training is train not wait" do
    {bundle, _} =
      Intent.resolve_bundle(
        "I spend three days training persuasion with Brenna",
        @inn_context
      )

    action = hd(bundle.actions)
    assert action.action_type == :train
    refute action.action_type == :wait
    assert action.parameters["ticks"] == 288
  end

  test "practice without a person stays wait" do
    {bundle, _} = Intent.resolve_bundle("I practice stealth for a day", @inn_context)
    assert hd(bundle.actions).action_type == :wait
  end

  test "happy path spends a day, one free attempt at +5, deducts the day fee", %{
    session: session
  } do
    session = seed_persuasion(session)
    before_coins = Inventory.coin_total_copper(session.world_state["character"]["coins"])
    before_tick = session.world_state["world_tick"]

    {_session, turn, payload} =
      train_sim(session, "I train persuasion with Brenna for a day", %{"persuasion" => 6})

    session = reload(session.id)
    character = session.world_state["character"]

    assert get_in(character, ["skills", "persuasion"]) == 4
    assert Map.get(character["learning_points"], "persuasion") == 0
    assert Map.get(character["learning_failures"], "persuasion") == 0
    assert Inventory.coin_total_copper(character["coins"]) == before_coins - 50
    assert session.world_state["world_tick"] == before_tick + 96
    assert payload.mechanical_resolution["training"] == "took_place"

    assert [
             %{
               "skill" => "persuasion",
               "roll" => 6,
               "raw_skill" => 3,
               "improved" => true,
               "bonus" => 5,
               "lp_spent" => 0,
               "trainer_npc_id" => "innkeep"
             }
           ] = turn.mechanical_resolution["improvements"]
  end

  test "three-day train still attempts one improvement", %{session: session} do
    session = seed_persuasion(session)
    before_coins = Inventory.coin_total_copper(session.world_state["character"]["coins"])

    {_session, turn, _payload} =
      train_sim(
        session,
        "I spend three days training persuasion with Brenna",
        %{"persuasion" => 1}
      )

    session = reload(session.id)
    assert length(turn.mechanical_resolution["improvements"]) == 1

    assert Inventory.coin_total_copper(session.world_state["character"]["coins"]) ==
             before_coins - 150
  end

  test "declined when trainer is not present", %{session: session} do
    session = seed_persuasion(session)
    before = snapshot(session)

    {_session, turn, payload} =
      train_sim(session, absent_osric_action(), %{"persuasion" => 20})

    session = reload(session.id)
    assert_unchanged(session, before)
    assert payload.mechanical_resolution["training"] == "declined"
    assert turn.mechanical_resolution["improvements"] == []
    assert session.world_state["world_tick"] == before.tick + 1
  end

  test "declined when the player cannot pay", %{session: session} do
    session =
      session
      |> seed_persuasion()
      |> put_character(&Map.put(&1, "coins", %{"gold" => 0, "silver" => 0, "copper" => 0}))

    before = snapshot(session)

    {_session, turn, payload} =
      train_sim(session, "I train persuasion with Brenna for a day", %{"persuasion" => 20})

    session = reload(session.id)
    assert_unchanged(session, before)
    assert payload.mechanical_resolution["training"] == "declined"
    assert turn.mechanical_resolution["improvements"] == []
  end

  test "declined when vitality is down", %{session: session} do
    session =
      session
      |> seed_persuasion()
      |> put_character(&Map.put(&1, "vitality", "down"))

    before = snapshot(session)

    {_session, turn, payload} =
      train_sim(session, "I train persuasion with Brenna for a day", %{"persuasion" => 20})

    session = reload(session.id)
    assert_unchanged(session, before)
    assert payload.mechanical_resolution["training"] == "declined"
    assert turn.mechanical_resolution["improvements"] == []
  end

  test "declined when vitality is dead", %{session: session} do
    session =
      session
      |> seed_persuasion()
      |> put_character(&Map.put(&1, "vitality", "dead"))

    before = snapshot(session)

    {_session, turn, payload} =
      train_sim(session, "I train persuasion with Brenna for a day", %{"persuasion" => 20})

    session = reload(session.id)
    assert_unchanged(session, before)
    assert payload.mechanical_resolution["training"] == "declined"
    assert turn.mechanical_resolution["improvements"] == []
  end

  test "default variant: no LP and no failure needed", %{session: session} do
    session = seed_bars(session, %{}, %{})

    {_session, turn, payload} =
      train_sim(session, "I train persuasion with Brenna for a day", %{"persuasion" => 20})

    assert payload.mechanical_resolution["training"] == "took_place"
    assert [%{"improved" => true, "lp_spent" => 0}] = turn.mechanical_resolution["improvements"]
    assert get_in(reload(session.id).world_state, ["character", "skills", "persuasion"]) == 4
  end

  test "baseline variant: declined when LP or failures are short" do
    {:ok, session} =
      GameSessions.create_session(%{
        name: "Trainers baseline",
        adventure_id: "tin_valley",
        variant: "baseline"
      })

    session =
      seed_bars(session, %{"persuasion" => 4.0}, %{"persuasion" => 3})

    before = snapshot(session)

    {_session, _turn, payload} =
      train_sim(session, "I train persuasion with Brenna for a day", %{"persuasion" => 20})

    session = reload(session.id)
    assert_unchanged(session, before)
    assert payload.mechanical_resolution["training"] == "declined"

    session =
      session
      |> seed_bars(%{"persuasion" => 5.0}, %{"persuasion" => 0})

    before = snapshot(session)

    {_session, _turn, payload} =
      train_sim(session, "I train persuasion with Brenna for a day", %{"persuasion" => 20})

    session = reload(session.id)
    assert_unchanged(session, before)
    assert payload.mechanical_resolution["training"] == "declined"
  end

  test "declined when Brenna has no authored stealth", %{session: session} do
    session =
      seed_bars(session, %{"stealth" => 0.5}, %{"stealth" => 3})

    before = snapshot(session)

    {_session, turn, payload} =
      train_sim(session, "I train stealth with Brenna for a day", %{"stealth" => 20})

    session = reload(session.id)
    assert_unchanged(session, before)
    assert payload.mechanical_resolution["training"] == "declined"
    assert turn.mechanical_resolution["improvements"] == []
  end

  test "baseline variant: qualifier fail does not rest all eligible skills" do
    {:ok, session} =
      GameSessions.create_session(%{
        name: "Trainers baseline",
        adventure_id: "tin_valley",
        variant: "baseline"
      })

    session =
      session
      |> seed_persuasion()
      |> seed_bars(
        %{"persuasion" => 5.0, "climbing" => 5.0},
        %{"persuasion" => 3, "climbing" => 3}
      )
      |> put_character(&put_in(&1, ["skills", "climbing"], 3))

    before = snapshot(session)

    train_sim(session, "I train stealth with Brenna for a day", %{
      "stealth" => 20,
      "climbing" => 20,
      "persuasion" => 20
    })

    session = reload(session.id)
    assert get_in(session.world_state, ["character", "skills", "climbing"]) == 3
    assert Map.get(session.world_state["character"]["learning_points"], "climbing") == 5.0
    assert_unchanged(session, before)
  end

  test "mechanical_bounds name training without +1", %{session: session} do
    session = seed_persuasion(session)
    {_session, _turn, payload} = train_sim(session, "I train persuasion with Brenna for a day")

    bounds =
      payload.mechanical_resolution
      |> MechanicalResolution.decode()
      |> Context.mechanical_bounds()

    assert bounds =~ "training: took_place"
    refute bounds =~ "+1"
    refute bounds =~ "improv"
    refute bounds =~ "learned"
  end

  test "declined bounds name training declined", %{session: session} do
    session = seed_persuasion(session)

    {_session, _turn, payload} = train_sim(session, absent_osric_action())

    bounds =
      payload.mechanical_resolution
      |> MechanicalResolution.decode()
      |> Context.mechanical_bounds()

    assert bounds =~ "training: declined"
    refute bounds =~ "+1"
  end

  test "train does not emit player.improved", %{session: session} do
    session = seed_persuasion(session)
    train_sim(session, "I train persuasion with Brenna for a day", %{"persuasion" => 1})

    kinds =
      SessionEvent
      |> where([e], e.game_session_id == ^session.id)
      |> select([e], e.kind)
      |> Repo.all()

    refute "player.improved" in kinds
  end

  test "train handler tick_delta matches wait" do
    player_action = train_action("I train persuasion with Brenna for a day")
    handler = ActionHandler.resolve(player_action)
    assert handler.handler == "train"
    assert ActionHandler.tick_delta(handler) == 96
  end

  test "session fee is per day with a one-day minimum" do
    assert Train.session_fee(50, 4) == 50
    assert Train.session_fee(50, 96) == 50
    assert Train.session_fee(50, 288) == 150
    assert Train.session_fee(80, WorldClock.ticks_per_day() * 2) == 160
  end

  # Bars a baseline session needs to train; the default variant ignores them,
  # and 0.0 LP leave nothing to spend at the end of the turn.
  defp seed_persuasion(%{world_state: %{"variant" => "baseline"}} = session) do
    seed_bars(session, %{"persuasion" => 5.0}, %{"persuasion" => 3})
  end

  defp seed_persuasion(session) do
    seed_bars(session, %{"persuasion" => 0.0}, %{"persuasion" => 0})
  end

  defp seed_bars(session, lp, failures) do
    put_character(session, fn character ->
      character
      |> Map.update("learning_points", lp, &Map.merge(&1, lp))
      |> Map.update("learning_failures", failures, &Map.merge(&1, failures))
    end)
  end

  defp put_character(session, fun) do
    character = fun.(session.world_state["character"])
    world = put_in(session.world_state, ["character"], character)

    session
    |> GameSession.changeset(%{world_state: world})
    |> Repo.update!()
  end

  defp train_sim(session, raw_or_action, rolls \\ %{})

  defp train_sim(session, raw, rolls) when is_binary(raw) do
    train_sim(session, train_action(raw), rolls)
  end

  defp train_sim(session, %PlayerAction{} = player_action, rolls) do
    handler = ActionHandler.resolve(player_action)

    {:ok, payload} =
      TurnProcessor.simulate!(
        session,
        player_action.overall_intent,
        player_action,
        handler,
        %MechanicalResolution{outcome: "none"},
        improvement_rolls: rolls
      )

    {reload(session.id), latest_turn(session.id), payload}
  end

  defp train_action(raw) do
    {bundle, _} = Intent.resolve_bundle(raw, @inn_context)
    Intent.validate_player_action(bundle, @inn_context)
  end

  defp absent_osric_action do
    %PlayerAction{
      overall_intent: "I train persuasion with Osric for a day",
      action: %SingleAction{
        action_type: :train,
        target: "guild_steward",
        parameters: %{"skill" => "persuasion", "ticks" => 96}
      }
    }
  end

  defp snapshot(session) do
    character = session.world_state["character"]

    %{
      skills: character["skills"],
      lp: character["learning_points"],
      failures: character["learning_failures"],
      coins: character["coins"],
      tick: session.world_state["world_tick"]
    }
  end

  defp assert_unchanged(session, before) do
    character = session.world_state["character"]
    assert character["skills"] == before.skills
    assert character["learning_points"] == before.lp
    assert character["learning_failures"] == before.failures
    assert character["coins"] == before.coins
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
