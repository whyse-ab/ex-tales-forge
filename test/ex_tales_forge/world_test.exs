defmodule TalesForge.WorldTest do
  @moduledoc """
  WORLD_AGENTS=on prototype: persons and locations are processes that hold
  facts; the GM gets them in the per-turn section and its new_facts are
  validated and written back to the owning agent. Default off.
  """
  use TalesForge.DataCase, async: false

  import Ecto.Query

  alias TalesForge.Config
  alias TalesForge.Game.{Context, Intent, Prompts, TurnProcessor}
  alias TalesForge.Game.Schemas.{GMStructuredResponse, MechanicalResolution, PlayerAction}
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.LLM
  alias TalesForge.Schemas.AICall
  alias TalesForge.World
  alias TalesForge.World.Agent

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
      for k <- ~w(WORLD_AGENTS XAI_API_KEY), do: System.delete_env(k)
      System.put_env("LLM_PROVIDER", "mock")
    end)

    {:ok, session} = GameSessions.create_session(%{name: "World", adventure_id: "tin_valley"})
    %{session: session}
  end

  test "off by default; the schema only gets new_facts with the flag, and no length limits" do
    refute Config.world_agents?()
    refute Map.has_key?(props(), "new_facts")

    System.put_env("WORLD_AGENTS", "on")
    assert World.enabled?()
    new_facts = props()["new_facts"]
    assert new_facts["items"]["required"] == ~w(about kind text)
    refute inspect(LLM.narration_schema()) =~ ~r/max(Length|Items)/
    assert prop_list() |> hd() |> elem(0) == "narrative"
    assert prop_list() |> List.last() |> elem(0) == "new_facts"
  end

  test "collect starts the location chain and the people present, in budget order", %{
    session: session
  } do
    agents = World.collect(session.id, session.world_state)

    assert Enum.map(agents, &{&1.id, &1.role}) == [
             {"valley_inn", :here},
             {"innkeep", :present},
             {"tin_valley_village", :around},
             {"tin_valley_region", :around}
           ]

    assert Enum.map(agents, & &1.name) ==
             ["Valley Inn", "Brenna Holt", "Tin Valley village", "Tin Valley"]

    assert is_pid(Agent.whereis(session.id, "valley_inn"))

    section = World.prompt_section(agents)
    assert section =~ "## World facts (true in this world; keep to them)"
    assert section =~ "- Valley Inn [valley_inn] (here): Mug of ale: 2 copper;"
    assert section =~ "Private room: 3 silver a night, paid up front"
    assert section =~ "- Brenna Holt [innkeep] (present):"
    assert section =~ "orc nest"
    assert String.length(section) < 1_500
    assert World.prompt_section([]) == nil
  end

  test "write_back validates new facts and routes them to the owning agent", %{
    session: session
  } do
    world = session.world_state
    agents = World.collect(session.id, world)

    new_facts = [
      %{
        "about" => "innkeep",
        "kind" => "promise",
        "text" => "Keep the back room for Lotta until dusk"
      },
      %{"about" => "[valley_inn]", "kind" => "price", "text" => "Stabling: 4 copper a night"},
      %{"about" => "valley_inn", "kind" => "price", "text" => "Room for the night: 2 silver"},
      %{"about" => "valley_inn", "kind" => "promise", "text" => "The inn promises nothing"},
      %{"about" => "harpy_roost", "kind" => "fact", "text" => "Harpies nest on the ridge"},
      %{
        "about" => "Brenna Holt",
        "kind" => "fact",
        "text" => "keep the back room for Lotta until dusk!"
      }
    ]

    {world, accepted, rejected} = World.write_back(world, agents, new_facts, 2)

    assert [
             {"innkeep", %{"kind" => "promise", "turn" => 2}},
             {"valley_inn", %{"kind" => "price"}}
           ] =
             accepted

    assert Enum.map(rejected, &elem(&1, 1)) ==
             [:price_conflict, :promise_not_person, :unknown_entity, :duplicate]

    assert [%{"text" => "Keep the back room for Lotta until dusk", "source" => "gm"}] =
             world["world_agents"]["innkeep"]["facts"]

    # After the turn is persisted the running agent has it ...
    :ok = World.commit(session.id, accepted, [%{"npc_id" => "innkeep", "emotion" => "wary"}])
    brenna = Agent.state(Agent.whereis(session.id, "innkeep"))
    assert Enum.any?(brenna.facts, &(&1["kind"] == "promise"))
    assert brenna.mood["emotion"] == "wary"

    # ... and a restarted agent rehydrates it from the snapshot.
    GenServer.stop(Agent.whereis(session.id, "innkeep"))
    agents = World.collect(session.id, world)

    assert World.prompt_section(agents) =~
             "promised: Keep the back room for Lotta until dusk (turn 2)"

    assert World.prompt_section(agents) =~ "Stabling: 4 copper a night (turn 2)"
  end

  test "the GM reply's new_facts are capped when parsed" do
    long = String.duplicate("x", 400)

    result =
      GMStructuredResponse.decode(%{
        "narrative" => "n",
        "new_facts" =>
          [%{"about" => "here", "kind" => "PRICE", "text" => long}, %{"bad" => 1}] ++
            for(i <- 1..5, do: %{"about" => "here", "text" => "f#{i}"})
      })

    assert [%{"kind" => "price", "text" => text}, %{"kind" => "fact"}, _] = result.new_facts
    assert String.length(text) == 160
    assert GMStructuredResponse.decode(%{"narrative" => "n"}).new_facts == []
  end

  test "facts are a per-turn section; the cached prefix is unchanged", %{session: session} do
    agents = World.collect(session.id, session.world_state)
    context = Context.build_gm_context(session)
    {action, handler} = action(context, "ask Brenna for a room")
    mech = %MechanicalResolution{}

    plain = Prompts.gm_messages(context, mech, action, handler, 2)

    with_facts =
      Prompts.gm_messages(Map.put(context, :world_facts, agents), mech, action, handler, 2)

    assert Enum.take(with_facts, 4) == Enum.take(plain, 4)
    assert List.last(with_facts).content =~ "## World facts"
    refute List.last(plain).content =~ "## World facts"
  end

  test "a turn with the flag on sends facts to the GM and writes its new facts back", %{
    session: session
  } do
    System.put_env("WORLD_AGENTS", "on")
    System.put_env("LLM_PROVIDER", "xai")
    System.put_env("XAI_API_KEY", "test-key")
    test_pid = self()

    content =
      Jason.encode!(%{
        "narrative" => "Brenna nods. \"Back room's yours till dusk.\"",
        "new_facts" => [
          %{"about" => "innkeep", "kind" => "promise", "text" => "Hold the back room until dusk"}
        ]
      })

    Req.Test.stub(TalesForge.LLM, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:gm, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
        "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 10}
      })
    end)

    {action, _} = action(Context.build_gm_context(session), "ask Brenna for a room")

    assert {:ok, _} =
             TurnProcessor.run(session.id, "ask Brenna for a room", PlayerAction.encode(action))

    assert_receive {:gm, body}
    assert List.last(body["messages"])["content"] =~ "Private room: 3 silver a night"
    assert body["response_format"]["json_schema"]["schema"]["properties"]["new_facts"]

    world = GameSessions.get_session!(session.id).world_state

    assert [%{"kind" => "promise", "text" => "Hold the back room until dusk", "turn" => 1}] =
             world["world_agents"]["innkeep"]["facts"]

    steps =
      Repo.all(
        from c in AICall,
          where: c.game_session_id == ^session.id and c.call_type == "function",
          select: c.purpose
      )

    assert "turn.world_facts" in steps
    assert "turn.world_writeback" in steps
  end

  defp props, do: Map.new(prop_list())
  defp prop_list, do: LLM.narration_schema()["properties"].values

  defp action(context, text) do
    action =
      text
      |> Intent.heuristic_intent(context.intent_context)
      |> Intent.validate_player_action(context.intent_context)

    {action, TalesForge.Game.ActionHandler.resolve(action)}
  end
end
