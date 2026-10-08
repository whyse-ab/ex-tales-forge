defmodule TalesForge.AICallsTest do
  use TalesForge.DataCase, async: false

  import ExUnit.CaptureLog

  alias TalesForge.AICalls
  alias TalesForge.Game.{Context, Intent, TurnProcessor}
  alias TalesForge.Game.Schemas.PlayerAction
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.PubSub.GameSession, as: SessionPubSub
  alias TalesForge.Schemas.{AICall, Turn}
  alias TalesForge.Workers.ProcessTurn

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
      Application.delete_env(:ex_tales_forge, :ai_spend_caps)
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

  test "records outside any transaction, as in production" do
    # The SQL sandbox wraps every test in a transaction; unboxed_run does not.
    unboxed = from(c in AICall, where: c.purpose == "unboxed")

    {rows, log} =
      with_log(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          try do
            :ok = AICalls.record(%{call_attrs(nil, %{cost_ticks: 10_000}) | purpose: "unboxed"})
            Repo.all(unboxed)
          after
            Repo.delete_all(unboxed)
          end
        end)
      end)

    refute log =~ "ai_call not recorded"
    assert [%AICall{cost_micro_usd: 1}] = rows
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

    assert [call] = Repo.all(from c in AICall, where: c.call_type == "llm")
    assert call.game_session_id == session.id
    assert call.conv_id == session.id
    assert %DateTime{} = call.started_at
    assert {call.adventure_id, call.game_system} == {"crossroads_ledger", "skill_d20"}
    assert call.turn_number == 1
    assert call.purpose == "gm"
    assert call.model == "xai/grok-4.20-0309-non-reasoning"
    assert call.status == "ok"
    assert {call.input_tokens, call.cached_tokens, call.output_tokens} == {2104, 1536, 187}
    assert call.reasoning_tokens == 0
    assert {call.cost_micro_usd, call.cost_source} == {1485, "provider"}
    assert call.latency_ms >= 0

    steps =
      Repo.all(
        from c in AICall,
          where: c.call_type == "function" and like(c.purpose, "turn.%"),
          order_by: c.started_at,
          select: {c.purpose, c.turn_number, c.status, c.cost_micro_usd, c.adventure_id}
      )

    assert steps == [
             {"turn.rules", 1, "ok", 0, "crossroads_ledger"},
             {"turn.player_quote", 1, "ok", 0, "crossroads_ledger"},
             {"turn.prompt", 1, "ok", 0, "crossroads_ledger"},
             {"turn.gm", 1, "ok", 0, "crossroads_ledger"},
             {"turn.persist", 1, "ok", 0, "crossroads_ledger"}
           ]
  end

  test "a failed GM call still records the steps that ran, the GM step as an error" do
    {session, player_action} = session_with_action()
    Req.Test.stub(TalesForge.LLM, &Plug.Conn.send_resp(&1, 500, "boom"))

    capture_log(fn ->
      assert {:error, _} = TurnProcessor.run(session.id, "look around the tavern", player_action)
    end)

    steps =
      Repo.all(
        from c in AICall,
          where: c.call_type == "function" and like(c.purpose, "turn.%"),
          order_by: c.started_at,
          select: {c.purpose, c.status}
      )

    assert steps == [
             {"turn.rules", "ok"},
             {"turn.player_quote", "ok"},
             {"turn.prompt", "ok"},
             {"turn.gm", "error"}
           ]
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

  describe "spend caps" do
    test "are off when unset" do
      {:ok, session} = GameSessions.create_session(%{name: "Uncapped"})
      :ok = AICalls.record(call_attrs(session.id, %{cost_ticks: 10_000_000_000}))

      assert AICalls.check_spend_caps(session.id) == :ok
      put_caps(session_micro_usd: nil, day_micro_usd: nil)
      assert AICalls.check_spend_caps(session.id) == :ok
    end

    test "session cap blocks that session only; calls without a session skip it" do
      {:ok, session} = GameSessions.create_session(%{name: "Session Cap"})
      {:ok, other} = GameSessions.create_session(%{name: "Session Cap Other"})
      :ok = AICalls.record(call_attrs(session.id, %{cost_ticks: 15_000_000}))
      put_caps(session_micro_usd: 1500)

      assert AICalls.check_spend_caps(session.id) == {:error, {:session, 1500, 1500}}
      assert AICalls.check_spend_caps(other.id) == :ok
      assert AICalls.check_spend_caps(nil) == :ok
    end

    test "day cap blocks every call, with or without a session" do
      {:ok, session} = GameSessions.create_session(%{name: "Day Cap"})
      :ok = AICalls.record(call_attrs(nil, %{cost_ticks: 10_000_000}))
      put_caps(day_micro_usd: 1000)

      assert AICalls.check_spend_caps(nil) == {:error, {:day, 1000, 1000}}
      assert AICalls.check_spend_caps(session.id) == {:error, {:day, 1000, 1000}}
    end

    test "bot calls (persona, scorer) are outside the session cap and game cost, inside the day cap" do
      {:ok, session} = GameSessions.create_session(%{name: "Bot Spend"})
      :ok = AICalls.record(call_attrs(session.id, %{cost_ticks: 10_000_000}))

      for purpose <- ~w(persona scorer) do
        :ok =
          AICalls.record(%{call_attrs(session.id, %{cost_ticks: 50_000_000}) | purpose: purpose})
      end

      assert AICalls.total_cost_for_session(session.id) == 1000
      put_caps(session_micro_usd: 1000)

      assert AICalls.check_spend_caps(session.id, "gm") == {:error, {:session, 1000, 1000}}
      assert AICalls.check_spend_caps(session.id, "persona") == :ok
      assert AICalls.check_spend_caps(session.id, "scorer") == :ok

      put_caps(day_micro_usd: 11_000)
      assert AICalls.check_spend_caps(session.id, "persona") == {:error, {:day, 11_000, 11_000}}
      assert AICalls.check_spend_caps(session.id, "scorer") == {:error, {:day, 11_000, 11_000}}
    end

    test "persona calls have a per-run cap that defaults to 0.50 USD" do
      {:ok, session} = GameSessions.create_session(%{name: "Persona Cap"})

      :ok =
        AICalls.record(%{
          call_attrs(session.id, %{cost_ticks: 4_999_990_000})
          | purpose: "persona"
        })

      assert AICalls.check_spend_caps(session.id, "persona") == :ok

      :ok = AICalls.record(%{call_attrs(session.id, %{cost_ticks: 10_000}) | purpose: "persona"})

      assert AICalls.check_spend_caps(session.id, "persona") ==
               {:error, {:persona_run, 500_000, 500_000}}

      assert AICalls.check_spend_caps(session.id, "gm") == :ok
      put_caps(persona_run_micro_usd: 600_000)
      assert AICalls.check_spend_caps(session.id, "persona") == :ok
    end

    test "the day starts at midnight Europe/Stockholm" do
      assert AICalls.day_start(~U[2026-10-06 21:59:59Z]) == ~U[2026-10-05 22:00:00Z]
      assert AICalls.day_start(~U[2026-10-06 22:00:00Z]) == ~U[2026-10-06 22:00:00Z]
      assert AICalls.day_start(~U[2026-10-25 12:00:00Z]) == ~U[2026-10-24 22:00:00Z]
      assert AICalls.day_start(~U[2026-12-01 10:00:00Z]) == ~U[2026-11-30 23:00:00Z]

      insert_cost!(5000, ~U[2026-10-05 21:59:59Z])
      insert_cost!(1000, ~U[2026-10-05 22:00:00Z])
      put_caps(day_micro_usd: 1000)

      assert AICalls.check_spend_caps(nil, "gm", ~U[2026-10-06 21:30:00Z]) ==
               {:error, {:day, 1000, 1000}}

      assert AICalls.check_spend_caps(nil, "gm", ~U[2026-10-06 22:00:00Z]) == :ok
    end

    test "a capped GM turn sends no request, writes a capped row and tells the player" do
      {session, player_action} = session_with_action()
      :ok = AICalls.record(call_attrs(session.id, %{cost_ticks: 15_000_000}))
      put_caps(session_micro_usd: 1000)
      SessionPubSub.subscribe(session.id)
      test_pid = self()

      Req.Test.stub(TalesForge.LLM, fn conn ->
        send(test_pid, :llm_request)
        Req.Test.json(conn, @xai_body)
      end)

      log =
        capture_log(fn ->
          assert {:error, {:spend_cap, :session}} =
                   TurnProcessor.run(session.id, "look around the tavern", player_action)
        end)

      refute_received :llm_request
      assert_received {:turn_failed, {:spend_cap, :session}}

      assert log =~
               "llm spend cap hit cap=session limit_usd=0.0010 spent_usd=0.0015 session=#{session.id}"

      refute Repo.get_by(Turn, game_session_id: session.id)

      assert %AICall{purpose: "gm", turn_number: 1, latency_ms: 0, cost_micro_usd: nil} =
               Repo.get_by!(AICall, game_session_id: session.id, status: "capped")

      job = %Oban.Job{
        args: %{
          "session_id" => session.id,
          "raw_action" => "look",
          "player_action" => player_action
        }
      }

      capture_log(fn -> assert {:cancel, {:spend_cap, :session}} = ProcessTurn.perform(job) end)
    end
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

  defp put_caps(caps), do: Application.put_env(:ex_tales_forge, :ai_spend_caps, caps)

  defp insert_cost!(micro_usd, inserted_at) do
    Repo.insert!(%AICall{
      purpose: "gm",
      model: "grok-4.3",
      status: "ok",
      latency_ms: 1,
      cost_micro_usd: micro_usd,
      inserted_at: inserted_at
    })
  end
end
