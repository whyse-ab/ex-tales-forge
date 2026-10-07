defmodule TalesForge.Game.ProseModeTest do
  @moduledoc """
  GM_REPLY_MODE=prose prototype: the GM streams narrative only (no
  response_format), NPC reactions come from Jev and notes/summary from a
  periodic small call, both applied at the start of the next turn. Schema mode
  stays the default.
  """
  use TalesForge.DataCase, async: false

  import Ecto.Query

  alias TalesForge.Config
  alias TalesForge.Game.{Context, Intent, Prompts, TurnProcessor}
  alias TalesForge.Game.Prose.{NpcReactions, Notes}
  alias TalesForge.Game.Schemas.PlayerAction
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.LLM
  alias TalesForge.Repo
  alias TalesForge.Schemas.AICall

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
      for k <- ~w(LLM_PROVIDER XAI_API_KEY GM_REPLY_MODE GM_NOTES_EVERY), do: System.delete_env(k)
      Application.put_env(:jev, :api_key, nil)
    end)

    :ok
  end

  test "schema is the default; only GM_REPLY_MODE=prose switches" do
    System.delete_env("GM_REPLY_MODE")
    assert Config.gm_reply_mode() == "schema"
    System.put_env("GM_REPLY_MODE", "PROSE")
    assert Config.gm_reply_mode() == "schema"
    System.put_env("GM_REPLY_MODE", "prose")
    assert Config.gm_reply_mode() == "prose"
  end

  test "prose GM messages keep the prefix and swap only the task message" do
    {:ok, session} = GameSessions.create_session(%{name: "Prose prompt"})
    context = Context.build_gm_context(session)
    {player_action, handler} = action(context, "look around the tavern")
    mech = %TalesForge.Game.Schemas.MechanicalResolution{}

    schema = Prompts.gm_messages(context, mech, player_action, handler, 1)
    prose = Prompts.gm_messages(context, mech, player_action, handler, 1, mode: :prose)

    assert Enum.take(prose, 2) == Enum.take(schema, 2)
    assert Enum.drop(prose, 3) == Enum.drop(schema, 3)
    assert Enum.at(prose, 2).content == Prompts.gm_prose_system()
    refute Prompts.gm_prose_system() =~ "JSON matching"
    assert Prompts.gm_prose_system() =~ "narrative only"

    scene = Prompts.scene_messages(context, mode: :prose)
    assert Enum.take(scene, 2) == Enum.take(prose, 2)
    assert Enum.at(scene, 2).content == Prompts.scene_prose_system()
  end

  test "a prose turn streams narrative only, records ttft, and schedules no bookkeeping fields" do
    {:ok, session} = GameSessions.create_session(%{name: "Prose turn"})
    player_action = encoded_action(session, "look around the tavern")

    System.put_env("LLM_PROVIDER", "xai")
    System.put_env("XAI_API_KEY", "test-key")
    System.put_env("GM_REPLY_MODE", "prose")
    # Notes only on turn 3+; Jev not configured: no follow-up calls here.
    test_pid = self()

    Req.Test.stub(TalesForge.LLM, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:request, Plug.Conn.get_req_header(conn, "x-grok-conv-id"), Jason.decode!(body)}
      )

      sse =
        [
          ~s({"choices":[{"delta":{"role":"assistant"}}]}),
          ~s({"choices":[{"delta":{"content":"Marta sets down "}}]}),
          ~s({"choices":[{"delta":{"content":"a mug."}}]}),
          ~s({"choices":[],"usage":{"prompt_tokens":900,"completion_tokens":12,"prompt_tokens_details":{"cached_tokens":800}}})
        ]
        |> Enum.map_join(&"data: #{&1}\n\n")
        |> Kernel.<>("data: [DONE]\n\n")

      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, sse)
    end)

    assert {:ok, %{turn_count: 1, entries: [_, gm]}} =
             TurnProcessor.run(session.id, "look around the tavern", player_action)

    assert gm.text == "Marta sets down a mug."

    session_id = session.id
    assert_received {:request, [^session_id], body}
    refute Map.has_key?(body, "response_format")
    assert body["stream"] == true
    assert Enum.at(body["messages"], 2)["content"] == Prompts.gm_prose_system()

    [call] =
      Repo.all(from c in AICall, where: c.game_session_id == ^session_id and c.purpose == "gm")

    assert call.cached_tokens == 800
    assert call.input_tokens == 900
    assert is_integer(call.ttft_ms)
  end

  test "sse_feed handles events split across chunks" do
    acc = %{buf: "", text: [], usage: nil, ttft: nil, raw: ""}
    started = System.monotonic_time(:millisecond)
    a = LLM.sse_feed(acc, ~s(data: {"choices":[{"delta":{"content":"Hel), 200, started)
    assert a.text == []

    b =
      LLM.sse_feed(
        a,
        ~s(lo"}}]}\n\ndata: {"choices":[],"usage":{"prompt_tokens":5}}\n\n),
        200,
        started
      )

    assert b.text == ["Hello"]
    assert b.usage == %{"prompt_tokens" => 5}
    assert is_integer(b.ttft)
    assert LLM.sse_feed(acc, "oops", 400, started).raw == "oops"
  end

  test "the prose scene sends no response_format and takes the location from the world" do
    System.put_env("LLM_PROVIDER", "xai")
    System.put_env("XAI_API_KEY", "test-key")
    test_pid = self()

    Req.Test.stub(TalesForge.LLM, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:body, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"content" => "You step inside."}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 3}
      })
    end)

    assert {:ok, %{location_name: "Valley Inn", narrative: "You step inside."}} =
             LLM.complete_scene_prose(
               [%{role: "user", content: "x"}],
               %{"location_name" => "Valley Inn"},
               session_id: nil
             )

    assert_received {:body, body}
    refute Map.has_key?(body, "response_format")
  end

  test "notes: parse tolerates bold tags; apply_latest only applies a newer summary" do
    assert %{
             "situation_lines" => ["- at the inn", "- Brenna wary"],
             "gm_notes" => "Hold back the nest."
           } =
             Notes.parse(
               "**SUMMARY:**\n**\n- at the inn\n- Brenna wary\n**NOTES:** Hold back the nest."
             )

    {:ok, session} = GameSessions.create_session(%{name: "Prose notes"})

    %TalesForge.Schemas.SessionEvent{}
    |> TalesForge.Schemas.SessionEvent.changeset(%{
      game_session_id: session.id,
      kind: "gm_notes",
      tick: 0,
      payload: %{"turn_number" => 3, "situation_lines" => ["- new"], "gm_notes" => "n"}
    })
    |> Repo.insert!()

    world = Notes.apply_latest(%{"situation_lines" => ["- old"]}, session.id)
    assert world["situation_lines"] == ["- new"]
    assert world["notes_applied_turn"] == 3

    assert Notes.apply_latest(
             %{"situation_lines" => ["- later"], "notes_applied_turn" => 3},
             session.id
           )["situation_lines"] == ["- later"]
  end

  test "notes are scheduled every GM_NOTES_EVERY turns on conv id <session>:notes" do
    System.put_env("GM_NOTES_EVERY", "2")
    assert Config.gm_notes_every() == 2
    assert LLM.conv_id(session_id: "abc", tier: :gm_notes) == "abc:notes"
  end

  test "Jev NPC reactions: questions per NPC, typed reactions, stored and shown next turn" do
    {:ok, session} = GameSessions.create_session(%{name: "Prose Jev"})
    Application.put_env(:jev, :api_key, "test")
    [inst | _] = TalesForge.NPC.list_instances(session.id)
    npc_id = inst.npc_id

    Req.Test.stub(Jev.HTTP, fn conn ->
      Jev.Test.respond(conn,
        npc0_present: 0.97,
        npc0_stance: :wary,
        npc0_emotion: :suspicion,
        npc0_intensity: 2.2,
        confidence: %{npc0_stance: 0.9, npc0_emotion: 0.8},
        usage: %{input_tokens: 500, output_tokens: 0}
      )
    end)

    assert {:ok, [r]} = NpcReactions.extract(session.id, 1, "Marta eyes the stranger.", [npc_id])

    assert %{
             "npc_id" => ^npc_id,
             "stance" => "wary",
             "emotion" => "suspicion",
             "intensity_label" => "moderate"
           } = r

    assert r["stance_confidence"] == 0.9

    [call] =
      Repo.all(
        from c in AICall, where: c.game_session_id == ^session.id and c.purpose == "jev_npc"
      )

    assert call.input_tokens == 500
    assert call.cost_micro_usd == 21

    world = NpcReactions.apply_latest(%{}, session.id)
    section = NpcReactions.prompt_section(world)
    assert section =~ "NPC reactions after turn 1"
    assert section =~ "wary, suspicion (moderate)"
  end

  defp action(context, text) do
    pa =
      text
      |> Intent.heuristic_intent(context.intent_context)
      |> Intent.validate_player_action(context.intent_context)

    {pa, TalesForge.Game.ActionHandler.resolve(pa)}
  end

  defp encoded_action(session, text) do
    context = Context.build_intent_context(session)

    text
    |> Intent.heuristic_intent(context)
    |> Intent.validate_player_action(context)
    |> PlayerAction.encode()
  end
end
