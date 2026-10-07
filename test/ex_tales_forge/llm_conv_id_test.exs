defmodule TalesForge.LLMConvIdTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.Game.Context
  alias TalesForge.Game.Intent
  alias TalesForge.Game.Schemas.PlayerAction
  alias TalesForge.Game.TurnProcessor
  alias TalesForge.GameSessions
  alias TalesForge.LLM

  @reply %{
    "choices" => [
      %{
        "message" => %{
          "role" => "assistant",
          "content" => ~s({"narrative":"ok","location_name":"Inn","action":"look"})
        }
      }
    ],
    "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2}
  }

  setup do
    System.put_env("LLM_PROVIDER", "xai")
    System.put_env("XAI_API_KEY", "test-key")

    on_exit(fn ->
      System.delete_env("LLM_PROVIDER")
      System.delete_env("XAI_API_KEY")
    end)

    test_pid = self()

    Req.Test.stub(TalesForge.LLM, fn conn ->
      send(test_pid, {:conv_id, Plug.Conn.get_req_header(conn, "x-grok-conv-id")})
      Req.Test.json(conn, @reply)
    end)

    :ok
  end

  test "a GM turn sends the game session id as x-grok-conv-id" do
    {:ok, session} = GameSessions.create_session(%{name: "Conv Id"})
    flush_conv_ids()
    context = Context.build_intent_context(session)

    player_action =
      "look around the tavern"
      |> Intent.heuristic_intent(context)
      |> Intent.validate_player_action(context)
      |> PlayerAction.encode()

    assert {:ok, _} = TurnProcessor.run(session.id, "look around the tavern", player_action)

    session_id = session.id
    assert_received {:conv_id, [^session_id]}
    refute_received {:conv_id, _}
  end

  test "persona calls for a session share the session's conv id" do
    {:ok, session} = GameSessions.create_session(%{name: "Conv Id Persona"})
    flush_conv_ids()
    session_id = session.id
    assert {:ok, _} = LLM.complete_persona("system", "user", session_id: session_id)
    assert_received {:conv_id, [^session_id]}
  end

  test "a call without a session uses a stable per-purpose conv id" do
    assert {:ok, _} = LLM.complete_scorer("system", "user", criteria: 0)
    assert {:ok, _} = LLM.complete_scorer("system", "user", criteria: 0)

    assert_received {:conv_id, ["tales-forge-scorer"]}
    assert_received {:conv_id, ["tales-forge-scorer"]}
  end

  test "conv_id/1 prefers the session id and falls back per purpose" do
    assert LLM.conv_id(session_id: "abc", tier: :tier2) == "abc"
    assert LLM.conv_id(session_id: nil, tier: :tier2) == "tales-forge-gm"
    assert LLM.conv_id(session_id: "", tier: :tier1) == "tales-forge-intent"
    assert LLM.conv_id([]) == "tales-forge-unknown"
  end

  defp flush_conv_ids do
    receive do
      {:conv_id, _} -> flush_conv_ids()
    after
      0 -> :ok
    end
  end
end
