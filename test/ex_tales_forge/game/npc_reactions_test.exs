defmodule TalesForge.Game.NpcReactionsTest do
  @moduledoc """
  NPC_REACTIONS=on prototype: Jev reads each present NPC's gut reaction before
  the GM call; the reaction goes into the per-turn prompt only and the mood
  carries over in world_state. Default off.
  """
  use TalesForge.DataCase, async: false

  import ExUnit.CaptureLog
  import Ecto.Query

  alias TalesForge.Config
  alias TalesForge.Game.{Context, Intent, NpcReactions, Prompts, TurnProcessor}
  alias TalesForge.Game.Schemas.{MechanicalResolution, PlayerAction}
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.NPC
  alias TalesForge.Schemas.AICall

  @xai_body %{
    "id" => "r1",
    "object" => "chat.completion",
    "model" => "grok-4.20-0309-non-reasoning",
    "choices" => [
      %{
        "index" => 0,
        "message" => %{
          "role" => "assistant",
          "content" => ~s({"narrative": "Brenna wipes the board and does not look up."})
        },
        "finish_reason" => "stop"
      }
    ],
    "usage" => %{
      "prompt_tokens" => 2000,
      "completion_tokens" => 100,
      "prompt_tokens_details" => %{"cached_tokens" => 1536}
    }
  }

  @wary [
    emotion: :wary,
    intensity: 2.8,
    stance: 1.2,
    confidence: %{emotion: 0.81, stance: 0.74},
    usage: %{input_tokens: 400}
  ]

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
      for k <- ~w(NPC_REACTIONS NPC_REACTIONS_TIMEOUT_MS XAI_API_KEY), do: System.delete_env(k)
      System.put_env("LLM_PROVIDER", "mock")
      Application.put_env(:jev, :api_key, nil)
    end)

    {:ok, session} = GameSessions.create_session(%{name: "Brenna", adventure_id: "tin_valley"})
    %{session: session}
  end

  test "off by default; NPC_REACTIONS=on needs a TypeSafe key too" do
    System.delete_env("NPC_REACTIONS")
    refute Config.npc_reactions?()
    System.put_env("NPC_REACTIONS", "on")
    assert Config.npc_reactions?()
    refute NpcReactions.enabled?()
    Application.put_env(:jev, :api_key, "test-key")
    assert NpcReactions.enabled?()
  end

  test "configured?/0 ignores TYPESAFE_API_KEY in the OS environment" do
    previous = System.get_env("TYPESAFE_API_KEY")

    on_exit(fn ->
      if previous,
        do: System.put_env("TYPESAFE_API_KEY", previous),
        else: System.delete_env("TYPESAFE_API_KEY")
    end)

    Application.put_env(:jev, :api_key, nil)
    System.put_env("TYPESAFE_API_KEY", "env-key")
    refute NpcReactions.configured?()
  end

  test "Brenna has the barkeep OCEAN scores (rework 2026-10-07)", %{session: session} do
    brenna = NPC.get_instance(session.id, "innkeep")

    assert get_in(brenna.personality, ["motivations", "personality_traits"]) == %{
             "openness" => 6,
             "conscientiousness" => 7,
             "extraversion" => 8,
             "agreeableness" => 8,
             "neuroticism" => 3
           }
  end

  test "Jev input is player-visible: OCEAN, mood, last narration, words and outcome", %{
    session: session
  } do
    brenna = NPC.get_instance(session.id, "innkeep")
    mech = %MechanicalResolution{skill: "persuasion", outcome: "failure"}
    scene = NpcReactions.situation(session.id, "I tell her I'm the Guild's new assessor", mech)
    state = NpcReactions.state(brenna, nil, scene)

    assert state =~ "NPC: Brenna Holt (innkeep)."
    assert state =~ "OCEAN (0-10): openness 6, conscientiousness 7"
    assert state =~ "Mood before this moment: neutral."
    assert state =~ "I tell her I'm the Guild's new assessor"
    assert state =~ "How it comes across: failure (persuasion attempt)."
    # The opening scene is what the player last heard.
    assert state =~ String.slice(GameSessions.opening_scene(session.id).narrative, -40, 40)
    refute state =~ "gm_notes"
    refute state =~ "secret"

    mood = %{"emotion" => "suspicious", "intensity" => 0.6, "stance" => "cool"}

    assert NpcReactions.state(brenna, mood, scene) =~
             "Mood before this moment: suspicious (0.6), stance cool."

    assert [emotion: {_, emotions}, intensity: {_, levels}, stance: {_, stances}] =
             NpcReactions.questions(brenna)

    assert emotions |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() ==
             NpcReactions.emotions()

    assert length(levels) == 5
    assert stances == ~w(hostile cool neutral warm friendly)
  end

  test "react/5 returns typed reactions, carries the mood and records jev rows", %{
    session: session
  } do
    jev_on()
    test_pid = self()

    Req.Test.stub(Jev.HTTP, fn conn ->
      {request, conn} = Jev.Test.request(conn)
      send(test_pid, {:jev, request})
      Jev.Test.respond(conn, @wary)
    end)

    world = session.world_state
    assert "innkeep" in world["present_npcs"]

    {[r], world} = NpcReactions.react(session.id, world, 1, "Any rooms?", %MechanicalResolution{})

    assert r["npc_id"] == "innkeep"
    assert r["name"] == "Brenna Holt"

    assert {r["emotion"], r["intensity"], r["stance"], r["confidence"]} ==
             {"wary", 0.7, "cool", 0.74}

    assert world["npc_moods"]["innkeep"]["emotion"] == "wary"
    assert_receive {:jev, request}
    assert inspect(request) =~ "Mood before this moment: neutral."

    # The next turn's call starts from the carried-over mood.
    {[_], _world} = NpcReactions.react(session.id, world, 2, "Please?", %MechanicalResolution{})
    assert_receive {:jev, request2}
    assert inspect(request2) =~ "Mood before this moment: wary (0.7), stance cool."

    rows = Repo.all(from c in AICall, where: c.purpose == "npc_reaction", order_by: c.turn_number)
    assert [%{call_type: "jev", status: "ok", turn_number: 1}, %{turn_number: 2}] = rows
    assert hd(rows).adventure_id == "tin_valley"
    assert hd(rows).cost_micro_usd == 17
  end

  test "an error or a timeout means no reaction, and the mood is kept", %{session: session} do
    jev_on()
    System.put_env("NPC_REACTIONS_TIMEOUT_MS", "100")
    world = Map.put(session.world_state, "npc_moods", %{"innkeep" => %{"emotion" => "calm"}})

    Req.Test.stub(Jev.HTTP, &Jev.Test.error(&1, 500, "boom"))

    capture_log(fn ->
      assert {[], ^world} = NpcReactions.react(session.id, world, 1, "Hi", nil)
    end)

    Req.Test.stub(Jev.HTTP, fn conn ->
      Process.sleep(1_000)
      Jev.Test.respond(conn, @wary)
    end)

    capture_log(fn ->
      assert {[], ^world} = NpcReactions.react(session.id, world, 2, "Hi", nil)
    end)

    assert Repo.all(from c in AICall, where: c.purpose == "npc_reaction", select: c.status) ==
             ["error", "error"]
  end

  test "the reaction is a per-turn line; the cached prefix is unchanged", %{session: session} do
    context = Context.build_gm_context(session)
    {action, handler} = action(context, "ask Brenna for a room")
    mech = %MechanicalResolution{}

    reaction = %{
      "name" => "Brenna Holt",
      "emotion" => "wary",
      "intensity" => 0.7,
      "stance" => "cool",
      "confidence" => 0.8
    }

    plain = Prompts.gm_messages(context, mech, action, handler, 2)

    with_reaction =
      Prompts.gm_messages(Map.put(context, :npc_reactions, [reaction]), mech, action, handler, 2)

    assert Enum.take(with_reaction, 4) == Enum.take(plain, 4)
    per_turn = List.last(with_reaction).content

    assert per_turn =~
             "## NPC reactions (this moment)\n- Brenna Holt — wary (0.7), stance cool, confidence 0.8"

    refute List.last(plain).content =~ "NPC reactions"
    assert Prompts.gm_system() =~ "NPC reactions (this moment)"
    assert NpcReactions.prompt_section([]) == nil
  end

  test "a turn with the flag on calls Jev before the GM and persists the mood", %{
    session: session
  } do
    jev_on()
    test_pid = self()
    System.put_env("LLM_PROVIDER", "xai")
    System.put_env("XAI_API_KEY", "test-key")

    Req.Test.stub(Jev.HTTP, fn conn ->
      send(test_pid, {:at, :jev, System.monotonic_time()})
      Jev.Test.respond(conn, @wary)
    end)

    Req.Test.stub(TalesForge.LLM, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:at, :gm, System.monotonic_time(), Jason.decode!(body)})
      Req.Test.json(conn, @xai_body)
    end)

    {action, _handler} = action(Context.build_gm_context(session), "ask Brenna for a room")

    assert {:ok, %{turn_count: 1}} =
             TurnProcessor.run(session.id, "ask Brenna for a room", PlayerAction.encode(action))

    assert_receive {:at, :jev, t_jev}
    assert_receive {:at, :gm, t_gm, body}
    assert t_jev < t_gm
    assert List.last(body["messages"])["content"] =~ "- Brenna Holt — wary (0.7), stance cool"

    world = GameSessions.get_session!(session.id).world_state
    assert world["npc_moods"]["innkeep"]["stance"] == "cool"

    purposes =
      Repo.all(
        from c in AICall,
          where: c.game_session_id == ^session.id and c.turn_number == 1,
          order_by: c.started_at,
          select: {c.call_type, c.purpose}
      )

    assert {"jev", "npc_reaction"} in purposes
    assert {"function", "turn.npc_reactions"} in purposes
  end

  test "with the flag off a turn makes no Jev call", %{session: session} do
    Application.put_env(:jev, :api_key, "test-key")
    System.put_env("LLM_PROVIDER", "xai")
    System.put_env("XAI_API_KEY", "test-key")
    Req.Test.stub(Jev.HTTP, fn _conn -> flunk("Jev called with NPC_REACTIONS off") end)
    Req.Test.stub(TalesForge.LLM, &Req.Test.json(&1, @xai_body))

    {action, _handler} = action(Context.build_gm_context(session), "ask Brenna for a room")

    assert {:ok, _} =
             TurnProcessor.run(session.id, "ask Brenna for a room", PlayerAction.encode(action))

    refute Map.has_key?(GameSessions.get_session!(session.id).world_state, "npc_moods")
    assert Repo.all(from c in AICall, where: c.purpose == "npc_reaction") == []
  end

  defp jev_on do
    System.put_env("NPC_REACTIONS", "on")
    Application.put_env(:jev, :api_key, "test-key")
  end

  defp action(context, text) do
    action =
      text
      |> Intent.heuristic_intent(context.intent_context)
      |> Intent.validate_player_action(context.intent_context)

    {action, TalesForge.Game.ActionHandler.resolve(action)}
  end
end
