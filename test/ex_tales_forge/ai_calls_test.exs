defmodule TalesForge.AICallsTest do
  use TalesForge.DataCase, async: false

  import ExUnit.CaptureLog

  alias TalesForge.AICalls
  alias TalesForge.Game.{Context, Intent, TurnProcessor}
  alias TalesForge.Game.Schemas.PlayerAction
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.Schemas.{AICall, Turn}

  # Shape of an xAI /v1/chat/completions response (docs.x.ai chat-completions reference).
  @xai_body %{
    "id" => "a3d1008e-4544-40d4-d075-11527e794e4a",
    "object" => "chat.completion",
    "created" => 1_759_759_200,
    "model" => "grok-4.20-0309-non-reasoning",
    "choices" => [
      %{
        "index" => 0,
        "message" => %{
          "role" => "assistant",
          "content" => ~s({"narrative": "Smoke curls under the low beams of the tavern."}),
          "refusal" => nil
        },
        "finish_reason" => "stop"
      }
    ],
    "usage" => %{
      "prompt_tokens" => 2104,
      "completion_tokens" => 187,
      "total_tokens" => 2291,
      "prompt_tokens_details" => %{
        "text_tokens" => 2104,
        "audio_tokens" => 0,
        "image_tokens" => 0,
        "cached_tokens" => 1536
      },
      "completion_tokens_details" => %{
        "reasoning_tokens" => 0,
        "audio_tokens" => 0,
        "accepted_prediction_tokens" => 0,
        "rejected_prediction_tokens" => 0
      },
      "num_sources_used" => 0,
      "cost_in_usd_ticks" => 14_847_000
    },
    "system_fingerprint" => "fp_3a7881249c"
  }

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
      System.put_env("LLM_PROVIDER", "mock")
      System.delete_env("XAI_API_KEY")
    end)

    :ok
  end

  describe "pricing" do
    test "bills uncached input, cached input and output plus reasoning at their rates" do
      usage = %{input_tokens: 2104, cached_tokens: 1536, output_tokens: 187, reasoning_tokens: 40}

      # 568 * 1.25 + 1536 * 0.20 + 227 * 2.50 = 710 + 307.2 + 567.5
      assert AICalls.price_table_cost("xai/grok-4.20-0309-non-reasoning", usage) == 1585
    end

    test "uses long-context rates once the prompt reaches the threshold" do
      usage = %{input_tokens: 200_000, cached_tokens: 0, output_tokens: 1000}

      assert AICalls.price_table_cost("grok-4.20-0309-non-reasoning", usage) == 505_000
    end

    test "unknown model costs nil and warns" do
      log =
        capture_log(fn ->
          assert AICalls.price_table_cost("xai/grok-nope", %{input_tokens: 10}) == nil
        end)

      assert log =~ "no LLM price for model=xai/grok-nope"
    end

    test "provider-billed ticks win over the price table" do
      assert AICalls.cost("grok-nope", %{input_tokens: 1, cost_ticks: 14_847_000}) ==
               {1485, "provider"}

      assert AICalls.cost("grok-4.3", %{input_tokens: 1000, output_tokens: 100}) ==
               {1500, "price_table"}

      assert AICalls.cost("grok-4.3", %{}) == {nil, nil}
    end
  end

  test "usage parses an xAI chat completion body" do
    assert AICalls.usage(@xai_body) == %{
             input_tokens: 2104,
             output_tokens: 187,
             cached_tokens: 1536,
             reasoning_tokens: 0,
             cost_ticks: 14_847_000
           }

    assert AICalls.usage(%{"choices" => []}) == %{}
  end

  test "totals sum cost per session and since a time" do
    {:ok, session} = GameSessions.create_session(%{name: "Cost Totals"})
    {:ok, other} = GameSessions.create_session(%{name: "Other Totals"})

    for {session_id, ticks} <- [
          {session.id, 10_000_000},
          {session.id, 5_000_000},
          {other.id, 1_000_000},
          {nil, 20_000}
        ] do
      :ok = AICalls.record(call_attrs(session_id, %{input_tokens: 1, cost_ticks: ticks}))
    end

    assert AICalls.total_cost_for_session(session.id) == 1500
    assert AICalls.total_cost_for_session(other.id) == 100
    assert AICalls.total_cost_since(DateTime.add(DateTime.utc_now(), -60)) == 1602
    assert AICalls.total_cost_since(DateTime.add(DateTime.utc_now(), 60)) == 0
  end

  test "a GM turn records an ai_call linked to the session and turn" do
    {session, player_action} = session_with_action()
    Req.Test.stub(TalesForge.LLM, &Req.Test.json(&1, @xai_body))

    assert {:ok, %{turn_count: 1}} =
             TurnProcessor.run(session.id, "look around the tavern", player_action)

    assert [call] = Repo.all(AICall)
    assert call.game_session_id == session.id
    assert call.turn_number == 1
    assert call.purpose == "gm"
    assert call.model == "xai/grok-4.20-0309-non-reasoning"
    assert call.status == "ok"
    assert {call.input_tokens, call.cached_tokens, call.output_tokens} == {2104, 1536, 187}
    assert call.reasoning_tokens == 0
    assert {call.cost_micro_usd, call.cost_source} == {1485, "provider"}
    assert call.latency_ms >= 0
  end

  test "a failed ai_call insert does not break the turn" do
    {session, player_action} = session_with_action()
    Req.Test.stub(TalesForge.LLM, &Req.Test.json(&1, @xai_body))
    Repo.query!("ALTER TABLE ai_calls ADD CONSTRAINT ai_calls_reject CHECK (false)")

    log =
      capture_log(fn ->
        assert {:ok, %{turn_count: 1}} =
                 TurnProcessor.run(session.id, "look around the tavern", player_action)
      end)

    assert log =~ "ai_call not recorded"
    assert Repo.get_by(Turn, game_session_id: session.id, turn_number: 1)
    assert Repo.all(AICall) == []
  end

  defp session_with_action do
    {:ok, session} = GameSessions.create_session(%{name: "Cost Turn"})
    context = Context.build_intent_context(session)

    player_action =
      "look around the tavern"
      |> Intent.heuristic_intent(context)
      |> Intent.validate_player_action(context)
      |> PlayerAction.encode()

    System.put_env("LLM_PROVIDER", "xai")
    System.put_env("XAI_API_KEY", "test-key")
    {session, player_action}
  end

  defp call_attrs(session_id, usage) do
    %{
      game_session_id: session_id,
      purpose: "gm",
      model: "grok-4.3",
      status: "ok",
      latency_ms: 5,
      usage: usage
    }
  end
end
