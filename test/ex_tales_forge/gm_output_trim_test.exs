defmodule TalesForge.GMOutputTrimTest do
  @moduledoc """
  The GM reply carries only what the code uses: narrative first, then small,
  capped bookkeeping (npc_memory_updates, context_summary, gm_notes).
  state_updates (discarded by TurnProcessor) and overlay_deltas (never read)
  are gone from the schema, the prompt and the struct.
  """
  use TalesForge.DataCase, async: false

  alias TalesForge.Game.{Context, Intent, Prompts, TurnProcessor}
  alias TalesForge.Game.Schemas.{GMStructuredResponse, PlayerAction}
  alias TalesForge.GameSessions
  alias TalesForge.GMReasoning
  alias TalesForge.Jido
  alias TalesForge.LLM
  alias TalesForge.NPC

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
      System.delete_env("LLM_PROVIDER")
      System.delete_env("XAI_API_KEY")
    end)

    :ok
  end

  test "the narration schema has narrative first and capped bookkeeping only" do
    schema = LLM.narration_schema()
    %Jason.OrderedObject{values: props} = schema["properties"]

    assert Enum.map(props, &elem(&1, 0)) ==
             ~w(narrative location_name npc_memory_updates context_summary gm_notes)

    props = Map.new(props)
    refute Map.has_key?(props, "state_updates")
    refute Map.has_key?(props, "overlay_deltas")

    assert props["gm_notes"]["maxLength"] == 240
    assert props["context_summary"]["maxLength"] == 300
    assert props["npc_memory_updates"]["maxItems"] == 3
    assert props["npc_memory_updates"]["items"]["properties"]["summary"]["maxLength"] == 160
    assert schema["required"] == ["narrative"]
  end

  test "the GM prompt no longer asks for state_updates or overlay_deltas" do
    gm = Prompts.gm_system()
    refute gm =~ "state_updates"
    refute gm =~ "overlay_deltas"
    assert gm =~ "gm_notes"
    assert gm =~ "context_summary"
    assert gm =~ "npc_memory_updates"
  end

  test "a reply with the removed fields still decodes; they are ignored" do
    legacy = %{
      "narrative" => "n",
      "state_updates" => [%{"path" => "npcs/marta_kellen.json", "patch" => %{"mood" => "angry"}}],
      "overlay_deltas" => %{"tension" => 0.2},
      "gm_notes" => "kept"
    }

    gm = GMStructuredResponse.decode(legacy)
    refute Map.has_key?(gm, :state_updates)
    refute Map.has_key?(gm, :overlay_deltas)
    assert gm.gm_notes == "kept"
    assert gm.raw == legacy
  end

  test "gm_notes, context_summary and NPC memories still reach reports and the next turn" do
    {:ok, session} = GameSessions.create_session(%{name: "Trimmed GM"})
    context = Context.build_intent_context(session)

    player_action =
      "look around the tavern"
      |> Intent.heuristic_intent(context)
      |> Intent.validate_player_action(context)
      |> PlayerAction.encode()

    System.put_env("LLM_PROVIDER", "xai")
    System.put_env("XAI_API_KEY", "test-key")

    reply = %{
      "narrative" => "Marta sets down a mug and watches the door.",
      "npc_memory_updates" => [
        %{"npc_id" => "marta_kellen", "summary" => "The stranger asked nothing and paid."}
      ],
      "context_summary" => "- Weary Pilgrim, evening\n- Marta is wary of the door",
      "gm_notes" => "Quiet look; Marta stays guarded."
    }

    Req.Test.stub(TalesForge.LLM, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => Jason.encode!(reply)}}],
        "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 40}
      })
    end)

    assert {:ok, %{turn_count: 1}} =
             TurnProcessor.run(session.id, "look around the tavern", player_action)

    session = GameSessions.get_session!(session.id)

    assert session.world_state["situation_lines"] ==
             ["- Weary Pilgrim, evening", "- Marta is wary of the door"]

    assert [event] = GMReasoning.list_for_session(session.id)
    assert event.payload["gm_notes"] == "Quiet look; Marta stays guarded."

    memories = NPC.get_instance(session.id, "marta_kellen").runtime_state["memories"]
    assert Enum.any?(memories, &(&1["summary"] =~ "asked nothing and paid"))

    # The next GM turn sees the summary as its situation.
    assert Context.format_gm_prompt(Context.build_gm_context(session)) =~
             "Marta is wary of the door"
  end
end
