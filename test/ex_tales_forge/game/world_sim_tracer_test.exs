defmodule TalesForge.Game.WorldSimTracerTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.Fronts
  alias TalesForge.Game.ActionHandler
  alias TalesForge.Game.Context
  alias TalesForge.Game.Fronts.Moves
  alias TalesForge.Game.Intent
  alias TalesForge.Game.Prompts
  alias TalesForge.Game.Schemas.{MechanicalResolution, PlayerAction}
  alias TalesForge.Game.WorldClock
  alias TalesForge.Game.TurnProcessor
  alias TalesForge.Game.WorldSim
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.Repo
  alias TalesForge.Schemas.{FrontInstance, SessionEvent}

  @arms "The camp is standing to arms — sentries doubled, fires banked, blades out."
  @hiring "The Miners Guild is hiring steel in the square — retainers with new spears, paid in advance."

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    {:ok, session} =
      GameSessions.create_session(%{name: "Tin Valley", adventure_id: "tin_valley"})

    %{session: session}
  end

  test "plain move onto orc_approach inserts hidden failed_notice and prepares nest", %{
    session: session
  } do
    session = session |> move("market_square") |> move("orc_approach")

    hidden =
      SessionEvent
      |> where([e], e.game_session_id == ^session.id and e.kind == "player.failed_notice")
      |> Repo.all()

    assert [%SessionEvent{player_aware: false, location_id: "orc_approach"}] = hidden

    nest = Fronts.get_instance(session.id, "orc_nest")
    assert get_in(nest.runtime_state, ["clocks", "alert", "value"]) == "prepared"
    assert Enum.any?(nest.runtime_state["memories"], &(&1["what"] =~ "approached"))
    assert Enum.any?(nest.runtime_state["public_facts"], &(&1["id"] == "nest_standing_to_arms"))

    prompt = Context.format_gm_prompt(Context.build_gm_context(session))
    scene = Prompts.build_scene_user(session)
    refute_leaked(prompt)
    refute_leaked(scene)
    refute prompt =~ @arms
    refute scene =~ @arms

    session = move(session, "orc_nest")
    prompt = Context.format_gm_prompt(Context.build_gm_context(session))
    scene = Prompts.build_scene_user(session)
    assert prompt =~ @arms
    assert scene =~ @arms
    refute prompt =~ ~r/"clocks"/
    refute prompt =~ ~r/"alert"/
    refute prompt =~ "resources.coin"
    refute scene =~ ~r/"clocks"/
  end

  test "noticed injection does not prepare the nest", %{session: session} do
    session = move(session, "market_square")

    session =
      move(session, "orc_approach", %MechanicalResolution{
        outcome: "success",
        skill: "stealth"
      })

    nest = Fronts.get_instance(session.id, "orc_nest")
    assert get_in(nest.runtime_state, ["clocks", "alert", "value"]) == "asleep"

    noticed =
      SessionEvent
      |> where([e], e.game_session_id == ^session.id and e.kind == "player.noticed")
      |> Repo.one()

    assert noticed.player_aware
  end

  test "cumulative dawdle writes hiring_steel; leaving town does not reset", %{session: session} do
    session = Enum.reduce(1..3, session, fn _, s -> look(s) end)
    guild = Fronts.get_instance(session.id, "miners_guild")
    assert get_in(guild.runtime_state, ["clocks", "clear_orcs", "value"]) == 3

    prompt = Context.format_gm_prompt(Context.build_gm_context(session))
    refute prompt =~ @hiring

    # market_square is still town (dawdle +1); mine_workings is not (clock holds).
    session = session |> move("market_square") |> move("mine_workings")
    guild = Fronts.get_instance(session.id, "miners_guild")
    assert get_in(guild.runtime_state, ["clocks", "clear_orcs", "value"]) == 4

    session =
      session
      |> move("market_square")
      |> then(&Enum.reduce(1..3, &1, fn _, s -> look(s) end))

    guild = Fronts.get_instance(session.id, "miners_guild")
    assert get_in(guild.runtime_state, ["clocks", "clear_orcs", "value"]) == 8

    prompt = Context.format_gm_prompt(Context.build_gm_context(session))
    scene = Prompts.build_scene_user(session)
    assert prompt =~ @hiring
    assert scene =~ @hiring
  end

  test "hiring_steel is skipped when coin is 0 at threshold", %{session: session} do
    guild = Fronts.get_instance(session.id, "miners_guild")

    runtime = put_in(guild.runtime_state, ["resources", "coin"], 0)

    guild
    |> FrontInstance.changeset(%{runtime_state: runtime})
    |> Repo.update!()

    session = Enum.reduce(1..8, session, fn _, s -> look(s) end)
    guild = Fronts.get_instance(session.id, "miners_guild")
    assert get_in(guild.runtime_state, ["clocks", "clear_orcs", "value"]) == 8
    refute Enum.any?(guild.runtime_state["public_facts"] || [], &(&1["id"] == "hiring_steel"))

    prompt = Context.format_gm_prompt(Context.build_gm_context(session))
    refute prompt =~ @hiring
  end

  test "opening prompt names Osric want and has no hiring_steel", %{session: session} do
    prompt = Context.format_gm_prompt(Context.build_gm_context(session))
    assert prompt =~ "Osric Vane wants the nest"
    refute prompt =~ @hiring
  end

  test "AFK without submit_message leaves clock and hiring_steel unchanged", %{session: session} do
    assert session.world_state["world_tick"] == WorldClock.default_start_tick()

    guild = Fronts.get_instance(session.id, "miners_guild")
    refute Enum.any?(guild.runtime_state["public_facts"] || [], &(&1["id"] == "hiring_steel"))
    assert get_in(guild.runtime_state, ["clocks", "clear_orcs", "value"]) == 0
  end

  test "this-turn wait GM prompt contains hiring_steel before persist", %{session: session} do
    raw = "I spend three days drinking and gambling at the inn"
    {bundle, _} = Intent.resolve_bundle(raw, %{"exits" => [], "present_npcs" => []})
    player_action = Intent.validate_player_action(bundle, %{})
    handler = ActionHandler.resolve(player_action)
    mechanical = %MechanicalResolution{outcome: "none"}
    character = Map.get(session.world_state, "character", %{})

    pre = Context.format_gm_prompt(Context.build_gm_context(session))
    refute pre =~ @hiring

    %{world: world_board} =
      TurnProcessor.apply_board(session, character, handler, player_action, mechanical)

    prompt =
      Context.format_gm_prompt(Context.build_gm_context(%{session | world_state: world_board}))

    assert prompt =~ @hiring

    guild = Fronts.get_instance(session.id, "miners_guild")
    refute Enum.any?(guild.runtime_state["public_facts"] || [], &(&1["id"] == "hiring_steel"))
  end

  test "one mug at the inn does not hire steel", %{session: session} do
    player_action =
      PlayerAction.decode(%{
        "overall_intent" => "I buy a mug of ale",
        "action" => %{
          "action_type" => "buy",
          "target" => "innkeep",
          "parameters" => %{
            "item_id" => "ale_mug",
            "npc_id" => "innkeep",
            "price_copper" => 2,
            "quantity" => 1
          }
        }
      })

    handler = ActionHandler.resolve(player_action)

    {:ok, _} =
      TurnProcessor.simulate!(
        session,
        "I buy a mug of ale",
        player_action,
        handler,
        %MechanicalResolution{outcome: "none"}
      )

    session = reload(session.id)
    guild = Fronts.get_instance(session.id, "miners_guild")
    assert get_in(guild.runtime_state, ["clocks", "clear_orcs", "value"]) == 1
    refute Enum.any?(guild.runtime_state["public_facts"] || [], &(&1["id"] == "hiring_steel"))

    prompt = Context.format_gm_prompt(Context.build_gm_context(session))
    refute prompt =~ @hiring
  end

  test "three days drinking at the inn hires steel in one wait", %{session: session} do
    raw = "I spend three days drinking and gambling at the inn"
    session = wait(session, raw)
    start = WorldClock.default_start_tick()

    assert session.world_state["world_tick"] == start + 288

    guild = Fronts.get_instance(session.id, "miners_guild")
    assert get_in(guild.runtime_state, ["clocks", "clear_orcs", "value"]) == 288
    assert Enum.any?(guild.runtime_state["public_facts"], &(&1["id"] == "hiring_steel"))

    prompt = Context.format_gm_prompt(Context.build_gm_context(session))
    scene = Prompts.build_scene_user(session)
    assert prompt =~ @hiring
    assert scene =~ @hiring
  end

  test "hire_extra with coin 0 is illegal" do
    state = %{"resources" => %{"coin" => 0}}
    defn = %{"id" => "miners_guild", "moves" => %{"hire_extra" => %{"wage" => 1}}}
    assert {:error, :illegal_move} = Moves.apply(state, "hire_extra", defn)
  end

  test "unknown front_id from a fake chronicler payload is dropped" do
    assert :drop = WorldSim.accept_chronicler_move(%{"front_id" => "lich_king"}, ["orc_nest"])

    assert {:ok, %{"front_id" => "orc_nest"}} =
             WorldSim.accept_chronicler_move(%{"front_id" => "orc_nest"}, ["orc_nest"])
  end

  defp move(session, location, mechanical \\ %MechanicalResolution{outcome: "none"}) do
    params =
      if mechanical.skill do
        %{"skill" => mechanical.skill}
      else
        %{}
      end

    raw = "go to the #{String.replace(location, "_", " ")}"

    player_action =
      PlayerAction.decode(%{
        "overall_intent" => raw,
        "action" => %{"action_type" => "move", "target" => location, "parameters" => params}
      })

    handler = ActionHandler.resolve(player_action)
    {:ok, _} = TurnProcessor.simulate!(session, raw, player_action, handler, mechanical)
    reload(session.id)
  end

  defp wait(session, raw) do
    {bundle, _} = Intent.resolve_bundle(raw, %{"exits" => [], "present_npcs" => []})
    player_action = Intent.validate_player_action(bundle, %{})
    handler = ActionHandler.resolve(player_action)

    {:ok, _} =
      TurnProcessor.simulate!(
        session,
        raw,
        player_action,
        handler,
        %MechanicalResolution{outcome: "none"}
      )

    reload(session.id)
  end

  defp look(session) do
    player_action =
      PlayerAction.decode(%{
        "overall_intent" => "look around",
        "action" => %{"action_type" => "observe", "target" => nil, "parameters" => %{}}
      })

    handler = ActionHandler.resolve(player_action)

    {:ok, _} =
      TurnProcessor.simulate!(
        session,
        "look around",
        player_action,
        handler,
        %MechanicalResolution{outcome: "none"}
      )

    reload(session.id)
  end

  defp reload(id) do
    id
    |> GameSessions.get_session!()
    |> Repo.preload([:front_instances, :npc_instances])
  end

  defp refute_leaked(text) do
    down = String.downcase(text)
    refute down =~ "prepared"
    refute down =~ "alert"
    refute down =~ "scout"
  end
end
