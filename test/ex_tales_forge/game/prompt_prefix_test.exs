defmodule TalesForge.Game.PromptPrefixTest do
  @moduledoc """
  Prefix stability for xAI prompt caching.

  The cache reuses the longest identical prefix of a request, so:
  - the shared narrator text and the rules must be byte-identical for the scene
    call and every GM turn, in every session of the same adventure;
  - session-stable content must not change between turns;
  - anything per-turn (state, turn numbers, the action) must come last.
  """
  use TalesForge.DataCase, async: false

  alias TalesForge.Game.Context
  alias TalesForge.Game.Prompts
  alias TalesForge.Game.Schemas.{HandlerResult, MechanicalResolution, PlayerAction, SingleAction}
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.LLM

  @per_turn_markers [
    "Validated player action (turn",
    "Action handler result:",
    "## Server resolution",
    "Current location:",
    "Player inventory:",
    "Situation:",
    "Recent turns:",
    "## Present NPCs",
    "## NPC Memories",
    "## NPC reactions",
    "## World facts",
    "## Prices this turn"
  ]

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    # Mock provider: the opening scene is written without an HTTP request.
    {:ok, a} = GameSessions.create_session(%{name: "Prefix A"})
    {:ok, b} = GameSessions.create_session(%{name: "Prefix B"})

    b = %{b | world_state: other_character(b.world_state)}
    %{a: a, b: b}
  end

  test "scene and GM prompts share a byte-identical prefix: narrator + rules", %{a: a, b: b} do
    scene_a = Prompts.scene_messages(Context.build_gm_context(a))
    gm_a1 = gm_messages(a, 1, "look around the tavern")
    gm_b7 = gm_messages(b, 7, "ask Marta about the ledger")

    shared = Enum.take(scene_a, 2)
    assert [%{role: "system"}, %{role: "system"}] = shared
    assert Enum.take(gm_a1, 2) == shared
    assert Enum.take(gm_b7, 2) == shared

    # The identical byte prefix of the flattened requests covers all of it.
    shared_bytes = shared |> Enum.map_join(& &1.content) |> byte_size()
    assert common_prefix_bytes(flat(scene_a), flat(gm_a1)) >= shared_bytes
    assert common_prefix_bytes(flat(gm_a1), flat(gm_b7)) >= shared_bytes

    # Rules are the big part worth caching.
    assert byte_size(Enum.at(shared, 1).content) > 10_000
  end

  test "the shared prefix holds no session or turn data", %{a: a, b: b} do
    for {session, turn} <- [{a, 1}, {b, 7}] do
      prefix =
        session
        |> gm_messages(turn, "look around")
        |> Enum.take(3)
        |> flat()

      refute prefix =~ session.id
      refute prefix =~ "Elara Voss"
      refute prefix =~ "Zed Quill"
      refute prefix =~ "## Session (fixed"
      refute prefix =~ "already told to the player"
      refute prefix =~ ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/

      for marker <- @per_turn_markers, do: refute(prefix =~ marker)
    end
  end

  test "session-stable content is identical on every turn of a session", %{a: a} do
    turn1 = gm_messages(a, 1, "look around the tavern")

    later_world =
      a.world_state
      |> put_in(["character", "coins"], %{"gold" => 0, "silver" => 3, "copper" => 7})
      |> put_in(["character", "wounds"], 2)
      |> Map.put("situation_lines", ["Marta has gone quiet."])
      |> Map.update("world_tick", 0, &(&1 + 9))

    turn5 = gm_messages(%{a | world_state: later_world}, 5, "leave without paying")

    # System + rules + task + session-stable: unchanged.
    assert Enum.take(turn5, 4) == Enum.take(turn1, 4)

    # Only the last message moved, and it carries the new values.
    [last1, last5] = [List.last(turn1).content, List.last(turn5).content]
    refute last1 == last5
    assert last5 =~ "Validated player action (turn 5)"
    assert last5 =~ "Marta has gone quiet."
    assert last5 =~ ~s("copper": 7)
  end

  test "per-turn content only appears after session-stable content", %{a: a} do
    messages = gm_messages(a, 3, "look around the tavern")

    assert Enum.map(messages, & &1.role) == ~w(system system system user user)

    [_narrator, _rules, _task, stable, per_turn] = messages
    assert stable.role == "user"
    assert stable.content =~ "## Session (fixed for this session)"
    assert stable.content =~ "character: Elara Voss (human)"
    assert stable.content =~ "already told to the player"

    stable_end =
      messages |> Enum.take(4) |> flat() |> byte_size()

    whole = flat(messages)

    for marker <- @per_turn_markers do
      {index, _len} = :binary.match(whole, marker)
      assert index >= stable_end, "#{marker} appears before the session-stable content ends"
      refute stable.content =~ marker
    end

    refute per_turn.content =~ "already told to the player"
    assert per_turn.content =~ "Validated player action (turn 3)"
  end

  test "narrator text is the same across adventures; the adventure's rules follow it", %{a: a} do
    {:ok, tin} = GameSessions.create_session(%{name: "Prefix Tin", adventure_id: "tin_valley"})

    [narrator_a, rules_a | _] = gm_messages(a, 1, "look around")
    [narrator_t, rules_t | _] = gm_messages(tin, 1, "look around")

    assert narrator_a == narrator_t
    assert narrator_a.content == Prompts.narrator_system()
    assert rules_a.content == Prompts.load_rules(a.world_state["adventure_id"])
    assert rules_t.content == Prompts.load_rules("tin_valley")
  end

  describe "on the wire" do
    setup do
      System.put_env("LLM_PROVIDER", "xai")
      System.put_env("XAI_API_KEY", "test-key")

      on_exit(fn ->
        System.delete_env("LLM_PROVIDER")
        System.delete_env("XAI_API_KEY")
      end)

      test_pid = self()

      Req.Test.stub(TalesForge.LLM, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        [conv_id] = Plug.Conn.get_req_header(conn, "x-grok-conv-id")
        send(test_pid, {:request, conv_id, Jason.decode!(body)})
        send(test_pid, {:raw_body, body})

        content = ~s({"narrative":"You arrive.","location_name":"The Weary Pilgrim"})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"role" => "assistant", "content" => content}}],
          "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 20}
        })
      end)

      :ok
    end

    test "scene call and GM turn 1 send the same cacheable prefix", %{a: a} do
      context = Context.build_gm_context(a)

      assert {:ok, _} =
               LLM.complete_scene(Prompts.scene_messages(context), context.intent_context,
                 session_id: a.id
               )

      assert_received {:request, scene_conv, scene}

      {player_action, handler} = action("look around the tavern")

      assert {:ok, _} =
               LLM.complete_turn(
                 gm_messages(a, 1, "look around the tavern"),
                 player_action,
                 handler,
                 1,
                 session_id: a.id
               )

      assert_received {:request, gm_conv, gm}

      # Same server, same response_format (xAI caches it ahead of the messages),
      # same first two messages.
      assert scene_conv == gm_conv
      assert scene["response_format"] == gm["response_format"]
      assert scene["response_format"]["json_schema"]["name"] == "narration"
      assert Enum.take(scene["messages"], 2) == Enum.take(gm["messages"], 2)
      refute Enum.at(scene["messages"], 2) == Enum.at(gm["messages"], 2)
    end

    test "two consecutive GM turns send a byte-identical prefix through session-stable",
         %{a: a} do
      {player_action, handler} = action("look around the tavern")

      assert {:ok, _} =
               LLM.complete_turn(
                 gm_messages(a, 1, "look around the tavern"),
                 player_action,
                 handler,
                 1,
                 session_id: a.id
               )

      assert_received {:request, conv1, gm1}
      assert_received {:raw_body, raw1}

      # Turn 2 of the same session: per-turn state has moved on.
      later_world =
        a.world_state
        |> put_in(["character", "wounds"], 1)
        |> Map.put("situation_lines", ["Marta has gone quiet."])
        |> Map.update("world_tick", 0, &(&1 + 1))

      {player_action2, handler2} = action("ask Marta about the ledger")

      assert {:ok, _} =
               LLM.complete_turn(
                 gm_messages(%{a | world_state: later_world}, 2, "ask Marta about the ledger"),
                 player_action2,
                 handler2,
                 2,
                 session_id: a.id
               )

      assert_received {:request, conv2, gm2}
      assert_received {:raw_body, raw2}

      assert conv1 == conv2
      assert gm1["response_format"] == gm2["response_format"]
      assert Enum.take(gm1["messages"], 4) == Enum.take(gm2["messages"], 4)
      refute List.last(gm1["messages"]) == List.last(gm2["messages"])

      # On the wire: the identical byte prefix of the two request bodies covers
      # narrator + rules + task + session-stable, with nothing per-turn before it.
      static_bytes =
        gm1["messages"] |> Enum.take(4) |> Enum.map_join(& &1["content"]) |> byte_size()

      common = common_prefix_bytes(raw1, raw2)
      assert common >= static_bytes

      {stable_at, _} = :binary.match(raw1, "## Session (fixed for this session)")
      assert stable_at < common

      for marker <- @per_turn_markers, {at, _} <- [:binary.match(raw1, marker)] do
        assert at > stable_at, "#{marker} is on the wire before the session-stable block"
      end
    end
  end

  # Every GM prompt here carries an NPC reaction line (NPC_REACTIONS=on), the
  # strictest case: it is per-turn and must stay out of the cached prefix.
  @reaction %{
    "name" => "Marta Kellen",
    "emotion" => "wary",
    "intensity" => 0.7,
    "stance" => "cool",
    "confidence" => 0.8
  }

  # ... and world facts (WORLD_AGENTS=on), also per-turn only.
  @world_facts [
    %{
      id: "taproom",
      name: "The taproom",
      kind: :location,
      role: :here,
      facts: [%{"kind" => "price", "text" => "Room: 3 silver", "source" => "pack"}]
    }
  ]

  defp gm_messages(session, turn_number, text) do
    {player_action, handler} = action(text)

    session
    |> Context.build_gm_context()
    |> Map.put(:npc_reactions, [@reaction])
    |> Map.put(:world_facts, @world_facts)
    |> Map.put(:price_lines, ["Purchase: Bowl of stew, 5 copper, paid (server)"])
    |> Prompts.gm_messages(
      %MechanicalResolution{skill: "insight", roll: 14, outcome: "success"},
      player_action,
      handler,
      turn_number
    )
  end

  defp action(text) do
    {%PlayerAction{
       overall_intent: text,
       action: %SingleAction{action_type: :observe, target: nil}
     }, %HandlerResult{handler: "observe", skill: "insight"}}
  end

  defp other_character(world) do
    world
    |> put_in(["character", "name"], "Zed Quill")
    |> put_in(["character", "race"], "elf")
    |> put_in(["character", "coins"], %{"gold" => 9, "silver" => 0, "copper" => 1})
    |> put_in(["character", "wounds"], 1)
    |> Map.put("situation_lines", ["Rain hammers the shutters."])
  end

  defp flat(messages), do: Enum.map_join(messages, & &1.content)

  defp common_prefix_bytes(a, b), do: :binary.longest_common_prefix([a, b])
end
