defmodule TalesForge.GMReasoningTest do
  use TalesForgeWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias TalesForge.Game.{Context, Intent, Perception, TurnProcessor}
  alias TalesForge.Game.Schemas.{GMStructuredResponse, PlayerAction}
  alias TalesForge.GameSessions
  alias TalesForge.GMReasoning
  alias TalesForge.Jido
  alias TalesForge.Repo
  alias TalesForge.Schemas.{GameSession, SessionEvent, Turn}

  @notes "Read it as a cautious look; failed roll, so Marta stays guarded. Withholding the smuggler's mark."

  @gm_reply %{
    "gm_notes" => @notes,
    "narrative" => "Smoke curls under the low beams. Marta watches you over a chipped mug.",
    "npc_memory_updates" => [],
    "mechanical_resolution" => %{"outcome" => "success"},
    "context_summary" => "- Weary Pilgrim, evening"
  }

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
      System.put_env("LLM_PROVIDER", "mock")
      System.delete_env("XAI_API_KEY")
    end)

    :ok
  end

  test "a GM turn stores its notes and raw reply as a hidden event", %{conn: conn} do
    {session, player_action} = session_with_action()
    stub_gm(@gm_reply)

    assert {:ok, %{turn_count: 1}} = TurnProcessor.run(session.id, "look around", player_action)

    turn = Repo.get_by!(Turn, game_session_id: session.id, turn_number: 1)
    assert [event] = GMReasoning.list_for_session(session.id)
    assert %SessionEvent{kind: "gm_reasoning", actor: "gm", player_aware: false} = event
    assert event.payload["gm_notes"] == @notes
    assert event.payload["gm_reply"] == @gm_reply
    assert event.payload["turn_id"] == turn.id
    assert event.payload["turn_number"] == 1
    refute Map.has_key?(event.payload, "what") or Map.has_key?(event.payload, "text")
    assert event.tick == GameSessions.get_session!(session.id).world_state["world_tick"]

    session = GameSessions.get_session!(session.id)
    refute turn.narrative =~ "smuggler"
    refute Context.format_gm_prompt(Context.build_gm_context(session)) =~ "smuggler"

    refute Enum.any?(
             Perception.visible_world(session)["player_aware_events"],
             &(&1["kind"] == "gm_reasoning")
           )

    System.put_env("LLM_PROVIDER", "mock")
    {:ok, _view, html} = live(conn, ~p"/play/#{session.id}")
    assert html =~ "Marta watches you"
    refute html =~ "smuggler"
  end

  test "missing gm_notes and the mock GM still store the raw reply, in turn order" do
    {:ok, session} = GameSessions.create_session(%{name: "Mock Reasoning"})

    assert {:ok, _} = GameSessions.submit_message(session.id, "look around the tavern")
    assert {:ok, _} = GameSessions.submit_message(session.id, "study the chalked slate")

    assert [first, second] = GMReasoning.list_for_session(session.id)
    assert {first.payload["turn_number"], second.payload["turn_number"]} == {1, 2}
    assert first.payload["gm_notes"] == nil
    assert first.payload["gm_reply"]["narrative"] =~ "Mock GM"

    assert GMStructuredResponse.decode(%{"narrative" => "x", "gm_notes" => ""}).gm_notes == nil
  end

  test "the turn completes when the reasoning insert fails" do
    {:ok, session} = GameSessions.create_session(%{name: "Reasoning Fails"})

    Repo.query!(
      "ALTER TABLE session_events ADD CONSTRAINT no_gm_reasoning CHECK (kind <> 'gm_reasoning')"
    )

    log =
      capture_log(fn ->
        assert {:ok, _} = GameSessions.submit_message(session.id, "look around the tavern")
      end)

    assert log =~ "gm reasoning not stored session=#{session.id}"
    assert Repo.get_by(Turn, game_session_id: session.id, turn_number: 1)
    assert GMReasoning.list_for_session(session.id) == []
  end

  test "a failed reasoning insert does not abort a real (non-sandbox) turn transaction" do
    # The sandbox runs each query under a savepoint, which hides aborted
    # transactions; unboxed_run uses a real one, as in production.
    {result, log} =
      with_log(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          session = Repo.insert!(%GameSession{name: "unboxed reasoning", world_state: %{}})

          try do
            turn = %Turn{id: Ecto.UUID.generate(), turn_number: 1}
            gm = GMStructuredResponse.decode(%{"narrative" => "n", "gm_notes" => "why"})

            {:ok, changes} =
              Ecto.Multi.new()
              |> Ecto.Multi.put(:turn, turn)
              |> GMReasoning.multi_insert(Ecto.UUID.generate(), 1, gm)
              |> Ecto.Multi.insert(:after, %SessionEvent{
                game_session_id: session.id,
                kind: "after",
                tick: 2
              })
              |> Repo.transaction()

            {changes, Repo.all(from e in SessionEvent, where: e.game_session_id == ^session.id)}
          after
            Repo.delete!(session)
          end
        end)
      end)

    assert {%{gm_reasoning: nil, after: %SessionEvent{}}, [%SessionEvent{kind: "after"}]} = result
    assert log =~ "gm reasoning not stored"
  end

  test "perception loads only player-aware events from the database" do
    {:ok, session} = GameSessions.create_session(%{name: "Perception SQL"})

    Repo.insert!(%SessionEvent{
      game_session_id: session.id,
      kind: "gm_reasoning",
      player_aware: false,
      tick: 1,
      payload: %{"gm_notes" => "hidden"}
    })

    handler = "perception-sql-#{inspect(self())}"
    test_pid = self()

    :telemetry.attach(
      handler,
      Repo.config()[:telemetry_prefix] ++ [:query],
      fn _event, _measurements, %{query: sql}, _ -> send(test_pid, {:sql, sql}) end,
      nil
    )

    visible = Perception.visible_world(GameSessions.get_session!(session.id))
    :telemetry.detach(handler)

    refute Enum.any?(visible["player_aware_events"], &(&1["kind"] == "gm_reasoning"))
    assert_received {:sql, sql} when is_binary(sql)
    events_sql = collect_sql([sql]) |> Enum.find(&(&1 =~ ~s(FROM "session_events")))
    assert [_select, where] = String.split(events_sql, "WHERE", parts: 2)
    assert where =~ ~s("player_aware")
  end

  defp collect_sql(acc) do
    receive do
      {:sql, sql} -> collect_sql([sql | acc])
    after
      0 -> acc
    end
  end

  defp stub_gm(reply) do
    Req.Test.stub(TalesForge.LLM, fn conn ->
      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => Jason.encode!(reply)}}],
        "usage" => %{"prompt_tokens" => 8600, "completion_tokens" => 330}
      })
    end)
  end

  defp session_with_action do
    {:ok, session} = GameSessions.create_session(%{name: "GM Reasoning"})
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
end
