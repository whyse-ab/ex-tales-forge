defmodule TalesForge.GMOutputTrimTest do
  @moduledoc """
  The GM reply carries only what the code uses: narrative first, then small,
  capped bookkeeping (npc_memory_updates, context_summary, gm_notes). The caps
  live in GMStructuredResponse.decode/1, not in the schema: maxLength /
  maxItems in the strict schema stop xAI from reusing the prompt cache.
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

  test "the narration schema has narrative first and bookkeeping only" do
    schema = LLM.narration_schema()
    %Jason.OrderedObject{values: props} = schema["properties"]

    assert Enum.map(props, &elem(&1, 0)) ==
             ~w(narrative location_name npc_memory_updates context_summary gm_notes)

    props = Map.new(props)
    refute Map.has_key?(props, "state_updates")
    refute Map.has_key?(props, "overlay_deltas")

    assert schema["required"] == ["narrative"]
  end

  test "the narration schema has no maxLength / maxItems (they disable xAI prompt caching)" do
    json = Jason.encode!(LLM.narration_schema())
    refute json =~ "maxLength"
    refute json =~ "maxItems"
    refute json =~ "minLength"
    refute json =~ "minItems"
  end

  test "decode enforces the bookkeeping caps the schema no longer carries" do
    long = String.duplicate("x", 1_000)

    gm =
      GMStructuredResponse.decode(%{
        "narrative" => long,
        "gm_notes" => long,
        "context_summary" => long,
        "npc_memory_updates" => for(i <- 1..5, do: %{"npc_id" => "npc_#{i}", "summary" => long})
      })

    caps = GMStructuredResponse.caps()
    assert gm.narrative == long
    assert String.length(gm.gm_notes) == caps.gm_notes
    assert String.length(gm.context_summary) == caps.context_summary
    assert length(gm.npc_memory_updates) == caps.npc_memory_items
    assert Enum.map(gm.npc_memory_updates, & &1["npc_id"]) == ~w(npc_1 npc_2 npc_3)

    assert Enum.all?(
             gm.npc_memory_updates,
             &(String.length(&1["summary"]) == caps.npc_memory_summary)
           )

    short = GMStructuredResponse.decode(%{"narrative" => "n", "gm_notes" => "ok"})
    assert short.gm_notes == "ok"
    assert short.context_summary == nil
    assert short.npc_memory_updates == []
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
