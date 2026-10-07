defmodule TalesForge.WorldTest do
  @moduledoc """
  WORLD_AGENTS=on prototype: persons and locations are processes that hold
  facts; the GM gets them in the per-turn section, prices come from code
  (`World.Prices`) and new facts and promises are read from the narration
  after the turn (`World.Extract`) and written back to the owning agent.
  Default off.
  """
  use TalesForge.DataCase, async: false

  import Ecto.Query

  alias TalesForge.Config
  alias TalesForge.Game.{Context, Intent, Prompts, TurnProcessor}
  alias TalesForge.Game.Schemas.{MechanicalResolution, PlayerAction}
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.LLM
  alias TalesForge.Schemas.AICall
  alias TalesForge.World
  alias TalesForge.Schemas.SessionEvent
  alias TalesForge.World.{Agent, Extract, Prices}

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
      for k <- ~w(WORLD_AGENTS XAI_API_KEY), do: System.delete_env(k)
      Application.delete_env(:ex_tales_forge, :world_extract_mode)
      System.put_env("LLM_PROVIDER", "mock")
    end)

    {:ok, session} = GameSessions.create_session(%{name: "World", adventure_id: "tin_valley"})
    %{session: session}
  end

  test "off by default; the GM schema has no new_facts (extraction replaced it)" do
    refute Config.world_agents?()
    System.put_env("WORLD_AGENTS", "on")
    assert World.enabled?()
    refute Map.has_key?(props(), "new_facts")
    refute inspect(LLM.narration_schema()) =~ ~r/max(Length|Items)/
    assert LLM.conv_id(tier: :fact_extract, session_id: "s1") == "s1:facts"
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

  test "validate_facts checks new facts; stored ones reach the agents and survive a restart", %{
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
      %{"about" => "innkeep", "kind" => "price", "text" => "Stew: 2 copper"},
      %{"about" => "valley_inn", "kind" => "promise", "text" => "The inn promises nothing"},
      %{"about" => "harpy_roost", "kind" => "fact", "text" => "Harpies nest on the ridge"},
      %{
        "about" => "Brenna Holt",
        "kind" => "fact",
        "text" => "keep the back room for Lotta until dusk!"
      }
    ]

    {accepted, rejected} = World.validate_facts(agents, new_facts, 2)

    assert [
             {"innkeep", %{"kind" => "promise", "turn" => 2, "source" => "narration"}},
             {"valley_inn", %{"kind" => "price"}}
           ] =
             accepted

    assert Enum.map(rejected, &elem(&1, 1)) ==
             [:price_conflict, :price_conflict, :promise_not_person, :unknown_entity, :duplicate]

    :ok = World.store_facts(session.id, accepted, 2)

    assert %{"innkeep" => [%{"text" => "Keep the back room for Lotta until dusk"}]} =
             World.stored_facts(session.id)

    refute Repo.exists?(
             from e in SessionEvent,
               where: e.game_session_id == ^session.id and e.player_aware == true
           )

    # The running agent gets it ...
    :ok = World.commit(session.id, accepted, [%{"npc_id" => "innkeep", "emotion" => "wary"}])
    brenna = Agent.state(Agent.whereis(session.id, "innkeep"))
    assert Enum.any?(brenna.facts, &(&1["kind"] == "promise"))
    assert brenna.mood["emotion"] == "wary"

    # ... and a restarted agent rehydrates it from the stored events.
    GenServer.stop(Agent.whereis(session.id, "innkeep"))
    GenServer.stop(Agent.whereis(session.id, "valley_inn"))
    agents = World.collect(session.id, world)

    assert World.prompt_section(agents) =~
             "promised: Keep the back room for Lotta until dusk (turn 2)"

    assert World.prompt_section(agents) =~ "Stabling: 4 copper a night (turn 2)"
  end

  describe "prices from code" do
    setup %{session: session} do
      %{agents: World.collect(session.id, session.world_state), world: session.world_state}
    end

    test "a question gets the listed price, nothing is charged", %{agents: agents, world: world} do
      {^world, lines} =
        Prices.resolve(agents, world, world, "Is there a room free, and a bowl of stew?", nil)

      assert lines == [
               "Price: Bowl of stew, 5 copper",
               "Price: Private room, one night, 3 silver"
             ] or
               lines == [
                 "Price: Private room, one night, 3 silver",
                 "Price: Bowl of stew, 5 copper"
               ]
    end

    test "handing over coins pays the listed price from the character's coins", %{
      agents: agents,
      world: world
    } do
      world = put_in(world, ["character", "coins"], %{"silver" => 1})

      {after_pay, lines} =
        Prices.resolve(agents, world, world, "I slide a silver coin over for the stew.", nil)

      assert lines == ["Purchase: Bowl of stew, 5 copper, paid (server)"]
      assert TalesForge.Game.Inventory.coin_total_copper(after_pay["character"]["coins"]) == 5
    end

    test "paying is a statement; a question only asks" do
      assert Prices.payment?(
               "Ah, two copper it is for that fine ale. What troubles these folk?",
               nil
             )

      assert Prices.payment?("Three silver for the room; here's the coin.", nil)
      assert Prices.payment?("I slide two coppers over. Enough?", nil)
      refute Prices.payment?("Could I pay for a room tonight?", nil)
      refute Prices.payment?("Two copper? For that?", nil)
      refute Prices.payment?("Is there stew tonight?", nil)
      refute Prices.payment?("I'll take the room gladly. Does the stew cost extra?", nil)
    end

    test "paying an amount without naming the item pays for what costs that", %{
      agents: agents,
      world: world
    } do
      text = "I place five copper coins on the bar. Any news from the valley?"
      {after_pay, lines} = Prices.resolve(agents, world, world, text, nil)
      assert lines == ["Purchase: Bowl of stew, 5 copper, paid (server)"]
      assert TalesForge.Game.Inventory.coin_total_copper(after_pay["character"]["coins"]) == 1095
      assert Prices.amount("three silver and five copper") == 35

      text = "I count out three silver and five copper and slide them over, taking the bowl."
      {_, lines} = Prices.resolve(agents, world, world, text, nil)

      assert Enum.sort(lines) == [
               "Purchase: Bowl of stew, 5 copper, paid (server)",
               "Purchase: Private room, one night, 3 silver, paid (server)"
             ]
    end

    test "paying buys what is named outside questions", %{agents: agents, world: world} do
      {_, lines} =
        Prices.resolve(agents, world, world, "I'll pay for the room. Is the stew any good?", nil)

      assert lines == ["Purchase: Private room, one night, 3 silver, paid (server)"]
    end

    test "the amount picks among the items named", %{agents: agents, world: world} do
      text = "Two copper it is for that fine ale. And aye, the stew sounds a blessing."
      {_, lines} = Prices.resolve(agents, world, world, text, nil)
      assert lines == ["Purchase: Mug of ale, 2 copper, paid (server)"]
    end

    test "too little money is reported, not charged", %{agents: agents, world: world} do
      world = put_in(world, ["character", "coins"], %{"copper" => 3})

      {^world, lines} =
        Prices.resolve(agents, world, world, "I pay for a room for the night.", nil)

      assert lines == ["Purchase: Private room, one night, 3 silver, not paid (has 3 copper)"]
    end

    test "nothing mentioned, no lines; money words", %{agents: agents, world: world} do
      assert {_, []} = Prices.resolve(agents, world, world, "I look around the common room.", nil)
      assert Prices.prompt_section([]) == nil
      assert Prices.money(30) == "3 silver"
      assert Prices.money(535) == "1 gold 3 silver 5 copper"
    end
  end

  test "extraction builds a small prompt from the turn's agents", %{session: session} do
    agents = World.collect(session.id, session.world_state)
    user = Extract.user(agents, "I ask about the orcs", "Brenna frowns.")
    assert user =~ "- innkeep: Brenna Holt (person, present)"
    assert user =~ "valley_inn: Mug of ale: 2 copper"
    assert user =~ "GM narration this turn:\nBrenna frowns."
    assert Extract.system() =~ ~s("about" must be one of the ids)
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

  test "a turn with the flag on prices in code, then extracts facts from the narration", %{
    session: session
  } do
    System.put_env("WORLD_AGENTS", "on")
    System.put_env("LLM_PROVIDER", "xai")
    System.put_env("XAI_API_KEY", "test-key")
    Application.put_env(:ex_tales_forge, :world_extract_mode, :sync)
    test_pid = self()

    gm = Jason.encode!(%{"narrative" => "Brenna nods. \"Back room's yours till dusk.\""})

    facts =
      Jason.encode!(%{
        "facts" => [
          %{"about" => "innkeep", "kind" => "promise", "text" => "Hold the back room until dusk"}
        ]
      })

    Req.Test.stub(TalesForge.LLM, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [conv] = Plug.Conn.get_req_header(conn, "x-grok-conv-id")
      body = Jason.decode!(body)
      send(test_pid, {:llm, conv, body})
      content = if String.ends_with?(conv, ":facts"), do: facts, else: gm

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
        "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 10}
      })
    end)

    text = "Is the back room free tonight?"
    {action, _} = action(Context.build_gm_context(session), text)

    assert {:ok, _} = TurnProcessor.run(session.id, text, PlayerAction.encode(action))

    session_id = session.id
    assert_receive {:llm, ^session_id, body}
    last = List.last(body["messages"])["content"]
    assert last =~ "Private room: 3 silver a night"
    assert last =~ "## Prices this turn"
    assert last =~ "Price: Private room, one night, 3 silver"
    refute body["response_format"]["json_schema"]["schema"]["properties"]["new_facts"]

    facts_conv = session.id <> ":facts"
    assert_receive {:llm, ^facts_conv, extract}
    assert List.last(extract["messages"])["content"] =~ "Back room's yours till dusk."

    assert %{"innkeep" => [%{"kind" => "promise", "text" => "Hold the back room until dusk"}]} =
             World.stored_facts(session.id)

    calls =
      Repo.all(
        from c in AICall,
          where: c.game_session_id == ^session.id,
          select: {c.call_type, c.purpose}
      )

    assert {"llm", "fact_extract"} in calls
    assert {"function", "turn.world_facts"} in calls
    assert {"function", "turn.prices"} in calls
    assert {"function", "turn.world_writeback"} in calls
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
