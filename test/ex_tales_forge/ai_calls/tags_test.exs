defmodule TalesForge.AICalls.TagsTest do
  use TalesForge.DataCase, async: false

  import ExUnit.CaptureLog

  alias TalesForge.AICalls
  alias TalesForge.AICalls.{Steps, Tags}
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.LLM
  alias TalesForge.Schemas.{AICall, GameSession}

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
      System.put_env("LLM_PROVIDER", "mock")
      System.delete_env("XAI_API_KEY")
    end)

    :ok
  end

  describe "Tags" do
    test "for_world: adventure id plus the default game system; an explicit system wins" do
      assert Tags.for_world(%{"adventure_id" => "tin_valley"}) ==
               %{adventure_id: "tin_valley", game_system: "skill_d20"}

      assert Tags.for_world(%{"adventure_id" => "merovingia_x", "game_system" => "merovingia"}) ==
               %{adventure_id: "merovingia_x", game_system: "merovingia"}

      assert Tags.for_world(%{}) == %{adventure_id: nil, game_system: nil}
      assert Tags.for_world(nil) == %{adventure_id: nil, game_system: nil}
    end

    test "for_session reads the session; unknown or malformed ids give nil tags" do
      {:ok, session} = GameSessions.create_session(%{name: "Tags", adventure_id: "tin_valley"})

      assert Tags.for_session(session.id) == %{
               adventure_id: "tin_valley",
               game_system: "skill_d20"
             }

      assert Tags.for_session(Ecto.UUID.generate()) == %{adventure_id: nil, game_system: nil}
      assert Tags.for_session("not-a-uuid") == %{adventure_id: nil, game_system: nil}
      assert Tags.for_session(nil) == %{adventure_id: nil, game_system: nil}
    end
  end

  describe "AICalls.record" do
    test "defaults to call_type llm and tags the row from its session" do
      {:ok, session} = GameSessions.create_session(%{name: "Rec", adventure_id: "tin_valley"})

      :ok =
        AICalls.record(%{
          game_session_id: session.id,
          purpose: "gm",
          model: "grok-4.3",
          status: "ok",
          latency_ms: 10,
          usage: %{input_tokens: 1000, output_tokens: 100}
        })

      assert %AICall{call_type: "llm", adventure_id: "tin_valley", game_system: "skill_d20"} =
               Repo.get_by!(AICall, game_session_id: session.id)
    end

    test "call_type follows the model when not given" do
      assert AICalls.call_type("jev-1.13.0") == "jev"
      assert AICalls.call_type("elixir") == "function"
      assert AICalls.call_type("xai/grok-4.20-0309-non-reasoning") == "llm"

      :ok =
        AICalls.record(%{
          purpose: "jev_npc",
          model: "jev-1.13.0",
          status: "ok",
          latency_ms: 90,
          usage: %{input_tokens: 400, cost_ticks: 170_000}
        })

      assert %AICall{call_type: "jev", cost_micro_usd: 17} =
               Repo.get_by!(AICall, purpose: "jev_npc")
    end

    test "explicit tags are kept as given" do
      :ok =
        AICalls.record(%{
          purpose: "intent",
          model: "grok-4.3",
          status: "ok",
          latency_ms: 1,
          adventure_id: "crossroads_ledger",
          game_system: "skill_d20"
        })

      assert %AICall{adventure_id: "crossroads_ledger"} = Repo.get_by!(AICall, purpose: "intent")
    end

    test "function rows cost exactly 0 with source free, and look up no price" do
      log =
        capture_log(fn ->
          Steps.record_one(%{purpose: "turn.rules", latency_ms: 3})
        end)

      refute log =~ "no LLM price"

      assert %AICall{call_type: "function", model: "elixir", cost_micro_usd: 0} =
               row =
               Repo.get_by!(AICall, purpose: "turn.rules")

      assert row.cost_source == "free"
    end

    test "an unknown call_type is rejected (logged, never raised)" do
      log =
        capture_log(fn ->
          AICalls.record(%{
            purpose: "x",
            model: "m",
            status: "ok",
            latency_ms: 1,
            call_type: "magic"
          })
        end)

      assert log =~ "ai_call not recorded"
      assert Repo.all(AICall) == []
    end

    test "function rows are not counted as calls in the spend buckets" do
      now = DateTime.utc_now()
      Steps.record_one(%{purpose: "turn.persist", latency_ms: 2})

      :ok =
        AICalls.record(%{
          purpose: "gm",
          model: "grok-4.3",
          status: "ok",
          latency_ms: 1,
          usage: %{input_tokens: 1000, output_tokens: 100}
        })

      buckets = AICalls.spend_by_bucket(DateTime.add(now, -60), DateTime.add(now, 60))
      assert buckets["game"].calls == 1
      assert buckets["game"].cost_micro_usd == 1500
    end
  end

  describe "LLM rows" do
    test "store the x-grok-conv-id they were sent with and their start time" do
      {:ok, session} = GameSessions.create_session(%{name: "Conv", adventure_id: "tin_valley"})
      System.put_env("LLM_PROVIDER", "xai")
      System.put_env("XAI_API_KEY", "test-key")
      parent = self()

      Req.Test.stub(TalesForge.LLM, fn conn ->
        send(parent, {:conv, Plug.Conn.get_req_header(conn, "x-grok-conv-id")})

        Req.Test.json(conn, %{
          "choices" => [%{"message" => %{"content" => ~s({"action": "wait"})}}],
          "usage" => %{"prompt_tokens" => 900, "completion_tokens" => 10}
        })
      end)

      before = DateTime.utc_now()

      assert {:ok, _} =
               LLM.complete_persona("sys", "user", session_id: session.id, turn_number: 2)

      assert_received {:conv, [conv]}

      assert %AICall{conv_id: ^conv, turn_number: 2, call_type: "llm"} =
               row =
               Repo.get_by!(AICall, purpose: "persona")

      assert conv == session.id <> ":persona"
      assert DateTime.compare(row.started_at, before) != :lt
      assert row.adventure_id == "tin_valley"
    end
  end

  describe "Steps" do
    test "time/2 outside collect/1 just runs the function" do
      assert Steps.time(:rules, fn -> :value end) == :value
      assert {:value, []} = Steps.collect(fn -> :value end)
    end

    test "collect/1 gathers steps in order with their status, and nests" do
      {result, steps} =
        Steps.collect(fn ->
          Steps.time(:rules, fn -> {:ok, 1} end)

          {_, inner} = Steps.collect(fn -> Steps.time(:inner, fn -> :ok end) end)
          send(self(), {:inner, inner})

          Steps.time(:gm, fn -> {:error, :boom} end)
        end)

      assert result == {:error, :boom}

      assert [%{purpose: "turn.rules", status: "ok"}, %{purpose: "turn.gm", status: "error"}] =
               steps

      assert_received {:inner, [%{purpose: "turn.inner"}]}
    end

    test "submitting an action records the intent step for the coming turn" do
      {:ok, session} = GameSessions.create_session(%{name: "Intent", adventure_id: "tin_valley"})
      assert {:ok, _} = GameSessions.submit_message(session.id, "look around")

      assert %AICall{call_type: "function", turn_number: 1, status: "ok"} =
               row =
               Repo.get_by!(AICall, game_session_id: session.id, purpose: "turn.intent")

      assert row.adventure_id == "tin_valley"
      assert Repo.get!(GameSession, session.id)
    end
  end
end
