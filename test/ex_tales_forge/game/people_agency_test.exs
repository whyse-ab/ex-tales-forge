defmodule TalesForge.Game.PeopleAgencyTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.Fronts
  alias TalesForge.Game.ActionHandler
  alias TalesForge.Game.Context
  alias TalesForge.Game.Events
  alias TalesForge.Game.Fronts.Moves
  alias TalesForge.Game.Intent
  alias TalesForge.Game.Prompts
  alias TalesForge.Game.Schemas.{MechanicalResolution, PlayerAction}
  alias TalesForge.Game.TurnProcessor
  alias TalesForge.Game.WorldSim
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.NPC
  alias TalesForge.Repo
  alias TalesForge.Schemas.{NpcInstance, SessionEvent}

  @hiring "The Miners Guild is hiring steel in the square — retainers with new spears, paid in advance."
  @blades "Osric Vane's hired blades watch the square — his own steel, not Guild retainers."
  @secret_what "tore the tin corner from the guild post; I will have them killed"

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    {:ok, session} =
      GameSessions.create_session(%{name: "Tin Valley", adventure_id: "tin_valley"})

    %{session: session}
  end

  test "mentioning a location fixture is interact" do
    context = %{
      "exits" => ["valley_inn"],
      "exit_names" => %{"valley_inn" => "Valley Inn"},
      "present_npcs" => [],
      "npc_details" => %{},
      "fixtures" => ["guild post", "stalls"]
    }

    {bundle, _} = Intent.resolve_bundle("I tear the tin prices off the guild post", context)
    action = hd(bundle.actions)
    assert action.action_type == :interact
    assert action.target == "guild post"
  end

  test "guild post interact slights Osric; he hires his own steel", %{session: session} do
    assert @blades != @hiring

    brenna_coin = npc_coin(session.id, "innkeep")
    caldern_coin = npc_coin(session.id, "prospector")

    session = session |> move("market_square") |> interact("guild post")

    slight =
      SessionEvent
      |> where([e], e.game_session_id == ^session.id and e.kind == "npc.slighted")
      |> Repo.one()

    assert %SessionEvent{player_aware: true, actor: "guild_steward", location_id: "market_square"} =
             slight

    osric = NPC.get_instance(session.id, "guild_steward")
    assert get_in(osric.runtime_state, ["resources", "coin"]) == 7

    assert Enum.any?(osric.runtime_state["memories"], fn mem ->
             mem["felt"] == "owed" and mem["secret"] == true
           end)

    assert Enum.any?(osric.runtime_state["public_facts"], &(&1["id"] == "osric_hired_blades"))

    guild = Fronts.get_instance(session.id, "miners_guild")
    assert get_in(guild.runtime_state, ["resources", "coin"]) == 40
    refute Enum.any?(guild.runtime_state["public_facts"] || [], &(&1["id"] == "hiring_steel"))
    refute Fronts.get_instance(session.id, "guild_steward")

    {prompt, scene} = prompts(session)
    assert prompt =~ @blades
    assert scene =~ @blades
    refute_plan_leak(prompt)
    refute_plan_leak(scene)

    session = move(session, "valley_inn")
    {prompt, scene} = prompts(session)
    assert prompt =~ @blades
    assert scene =~ @blades
    refute_plan_leak(prompt)
    refute_plan_leak(scene)

    session = move(session, "mine_workings")
    {prompt, scene} = prompts(session)
    refute prompt =~ @blades
    refute scene =~ @blades
    refute_plan_leak(prompt)
    refute_plan_leak(scene)

    brenna = NPC.get_instance(session.id, "innkeep")
    caldern = NPC.get_instance(session.id, "prospector")

    refute Enum.any?(
             brenna.runtime_state["public_facts"] || [],
             &(&1["id"] == "osric_hired_blades")
           )

    refute Enum.any?(
             caldern.runtime_state["public_facts"] || [],
             &(&1["id"] == "osric_hired_blades")
           )

    assert npc_coin(session.id, "innkeep") == brenna_coin
    assert npc_coin(session.id, "prospector") == caldern_coin
  end

  test "broke Osric marks the debt and cannot hire", %{session: session} do
    set_npc_coin!(session.id, "guild_steward", 0)
    session = session |> move("market_square") |> interact("guild post")

    osric = NPC.get_instance(session.id, "guild_steward")
    assert get_in(osric.runtime_state, ["resources", "coin"]) == 0

    refute Enum.any?(
             osric.runtime_state["public_facts"] || [],
             &(&1["id"] == "osric_hired_blades")
           )

    assert Enum.any?(osric.runtime_state["memories"], fn mem ->
             mem["felt"] == "owed" and mem["secret"] == true
           end)

    {prompt, _scene} = prompts(session)
    refute prompt =~ @blades
  end

  test "wait three days without a slight is Guild hiring only", %{session: session} do
    session = wait(session, "I spend three days drinking and gambling at the inn")
    {prompt, scene} = prompts(session)
    assert prompt =~ @hiring
    assert scene =~ @hiring
    refute prompt =~ @blades
    refute scene =~ @blades
  end

  test "slight then wait three days at the inn shows both sentences", %{session: session} do
    session =
      session
      |> move("market_square")
      |> interact("guild post")
      |> move("valley_inn")
      |> wait("I spend three days drinking and gambling at the inn")

    {prompt, scene} = prompts(session)
    assert prompt =~ @hiring
    assert prompt =~ @blades
    assert scene =~ @hiring
    assert scene =~ @blades
  end

  test "Crossroads GM prompt still Marta/ledger/ale with no blades" do
    {:ok, session} = GameSessions.create_session(%{name: "Crossroads"})
    prompt = Context.format_gm_prompt(Context.build_gm_context(session))

    assert prompt =~ "Marta"
    assert prompt =~ "missing ledger"
    assert prompt =~ "ale" or prompt =~ "Mug of Ale"
    refute prompt =~ @blades
  end

  test "hire_extra with coin 0 is illegal" do
    state = %{"resources" => %{"coin" => 0}}
    defn = %{"id" => "guild_steward", "moves" => %{"hire_extra" => %{"wage" => 1}}}
    assert {:error, :illegal_move} = Moves.apply(state, "hire_extra", defn)
  end

  test "Caldern does not hire when Osric is the slighted actor" do
    osric = person("osric", slight_hire_def())
    caldern = person("caldern", slight_hire_def())

    {:ok, sim} =
      WorldSim.tick(%{
        fronts: [],
        people: [osric, caldern],
        events: [%{"kind" => "npc.slighted", "actor" => "osric"}]
      })

    by_id = Map.new(sim.people, &{&1.npc_id, &1})

    assert get_in(by_id["osric"].runtime_state, ["resources", "coin"]) == 7
    assert Enum.any?(by_id["osric"].runtime_state["public_facts"], &(&1["id"] == "hired_blades"))

    assert get_in(by_id["caldern"].runtime_state, ["resources", "coin"]) == 12

    refute Enum.any?(
             by_id["caldern"].runtime_state["public_facts"],
             &(&1["id"] == "hired_blades")
           )
  end

  test "blank slight actor is a broadcast" do
    caldern = person("caldern", slight_hire_def())

    {:ok, sim} =
      WorldSim.tick(%{
        fronts: [],
        people: [caldern],
        events: [%{"kind" => "npc.slighted", "actor" => nil}]
      })

    [updated] = sim.people
    assert get_in(updated.runtime_state, ["resources", "coin"]) == 7
    assert Enum.any?(updated.runtime_state["public_facts"], &(&1["id"] == "hired_blades"))
  end

  test "other targeting a watched fixture emits npc.slighted" do
    people = [
      %{
        npc_id: "steward",
        definition: %{
          "triggers" => [
            %{
              "on" => "interact",
              "location_id" => "square",
              "target_in" => ["notice board"],
              "event" => "npc.slighted",
              "player_aware" => true
            }
          ]
        }
      }
    ]

    player_action =
      PlayerAction.decode(%{
        "overall_intent" => "I wreck the notice board",
        "action" => %{
          "action_type" => "other",
          "target" => "notice board",
          "parameters" => %{}
        }
      })

    world = %{"character" => %{"location_id" => "square"}, "world_tick" => 1}

    events =
      Events.from_turn(
        player_action,
        ActionHandler.resolve(player_action),
        %MechanicalResolution{outcome: "none"},
        world,
        world,
        [],
        people
      )

    slight = Enum.find(events, &(&1["kind"] == "npc.slighted"))

    assert %{"actor" => "steward", "location_id" => "square", "player_aware" => true} = slight
  end

  defp interact(session, target) do
    raw = "I wreck the #{target}"

    player_action =
      PlayerAction.decode(%{
        "overall_intent" => raw,
        "action" => %{
          "action_type" => "interact",
          "target" => target,
          "parameters" => %{"skill" => "insight"}
        }
      })

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

  defp move(session, location) do
    raw = "go to the #{String.replace(location, "_", " ")}"

    player_action =
      PlayerAction.decode(%{
        "overall_intent" => raw,
        "action" => %{"action_type" => "move", "target" => location, "parameters" => %{}}
      })

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

  defp reload(id) do
    id
    |> GameSessions.get_session!()
    |> Repo.preload([:front_instances, :npc_instances])
  end

  defp prompts(session) do
    {
      Context.format_gm_prompt(Context.build_gm_context(session)),
      Prompts.build_scene_user(session)
    }
  end

  defp npc_coin(session_id, npc_id) do
    session_id
    |> NPC.get_instance(npc_id)
    |> Map.get(:runtime_state, %{})
    |> get_in(["resources", "coin"])
  end

  defp set_npc_coin!(session_id, npc_id, coin) do
    inst = NPC.get_instance(session_id, npc_id)
    runtime = put_in(inst.runtime_state, ["resources", "coin"], coin)

    inst
    |> NpcInstance.changeset(%{runtime_state: runtime})
    |> Repo.update!()
  end

  defp refute_plan_leak(text) do
    refute text =~ @secret_what
    refute text =~ ~r/\bowed\b/
    refute text =~ ~r/\bkill/
    refute text =~ "resources.coin"
    refute text =~ ~r/"wage"/
    refute text =~ "agreeableness_lte"
    refute text =~ "if_felt"
  end

  defp person(npc_id, defn) do
    %{
      npc_id: npc_id,
      definition: defn,
      runtime_state: %{
        "resources" => %{"coin" => 12},
        "public_facts" => [],
        "memories" => []
      }
    }
  end

  defp slight_hire_def do
    %{
      "motivations" => %{"personality_traits" => %{"agreeableness" => 2}},
      "rules" => [
        %{"id" => "remember_slight", "on_event" => "npc.slighted", "move" => "mark_debt"},
        %{
          "id" => "hire_on_slight",
          "on_event" => "npc.slighted",
          "if_felt" => "owed",
          "agreeableness_lte" => 3,
          "move" => "hire_extra"
        }
      ],
      "moves" => %{
        "mark_debt" => %{"memory" => %{"felt" => "owed"}},
        "hire_extra" => %{
          "wage" => 5,
          "public_fact" => %{"id" => "hired_blades", "text" => "hired blades"}
        }
      }
    }
  end
end
