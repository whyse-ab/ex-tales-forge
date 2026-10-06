defmodule TalesForge.Playtest.RunnerTest do
  use TalesForge.DataCase, async: false

  import Ecto.Query

  alias TalesForge.GMReasoning
  alias TalesForge.Jido
  alias TalesForge.Playtest.Runner
  alias TalesForge.Schemas.{AICall, GameSession, SessionEvent, Turn}

  @gm_reply %{
    "narrative" => "The lamp gutters as the innkeeper eyes you.",
    "gm_notes" => "SECRET-GM-NOTE"
  }

  setup do
    Application.put_env(:ex_tales_forge, :playtest_runner_enabled, true)

    on_exit(fn ->
      for pid <- Task.Supervisor.children(TalesForge.Playtest.Supervisor),
          do: Task.Supervisor.terminate_child(TalesForge.Playtest.Supervisor, pid)

      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
      System.put_env("LLM_PROVIDER", "mock")
      System.delete_env("XAI_API_KEY")
      System.delete_env("TIER1_HEURISTIC_THRESHOLD")
      Application.delete_env(:ex_tales_forge, :ai_spend_caps)
      Application.delete_env(:ex_tales_forge, :playtest_runner_enabled)
    end)

    :ok
  end

  test "plays to the turn limit and records the run" do
    {:ok, run_id} = Runner.start("paul", "tin_valley", turn_limit: 2, notes: "smoke")

    assert {:ok, run} = await(run_id)
    assert %{status: "finished", stop_reason: "turn_limit", turns_played: 2, turn_limit: 2} = run
    assert %{persona: "paul", module: "tin_valley", notes: "smoke"} = run
    assert run.build =~ "0.1.0"
    assert run.finished_at
    assert turns(run.game_session_id) |> length() == 2
  end

  test "is off unless enabled, and checks persona and module" do
    sessions = Repo.aggregate(GameSession, :count)

    Application.put_env(:ex_tales_forge, :playtest_runner_enabled, false)
    assert Runner.start("paul", "tin_valley") == {:error, :disabled}

    Application.put_env(:ex_tales_forge, :playtest_runner_enabled, true)
    assert Runner.start("nobody", "tin_valley") == {:error, :unknown_persona}
    assert Runner.start("paul", "../adventures") == {:error, :unknown_module}
    assert Runner.status(Ecto.UUID.generate()) == {:error, :not_found}
    assert Runner.status("not-a-uuid") == {:error, :not_found}
    assert Repo.aggregate(GameSession, :count) == sessions
  end

  test "stops on a spend cap at the persona's call" do
    put_caps(session_micro_usd: 1_000)
    stub_llm(fn _kind, _user -> :default end)

    {:ok, run_id} = Runner.start("hawk", "tin_valley")

    assert {:ok, %{status: "stopped", stop_reason: "spend_cap", turns_played: 0} = run} =
             await(run_id)

    assert %AICall{status: "capped"} =
             Repo.get_by(AICall, game_session_id: run.game_session_id, purpose: "persona")
  end

  test "stops when the GM turn hits the spend cap" do
    put_caps(session_micro_usd: 3_000)
    stub_llm(fn _kind, _user -> :default end)

    {:ok, run_id} = Runner.start("lars", "tin_valley")

    assert {:ok, %{status: "stopped", stop_reason: "spend_cap", turns_played: 0} = run} =
             await(run_id)

    calls = calls(run.game_session_id)
    assert {"persona", "ok"} in calls
    assert {"gm", "capped"} in calls
  end

  test "answers a clarification by picking an option" do
    test_pid = self()
    # Send every action to the intent LLM, which asks back.
    System.put_env("TIER1_HEURISTIC_THRESHOLD", "1.0")

    stub_llm(fn
      :persona, user ->
        send(test_pid, {:persona_prompt, user})

        if user =~ "The Game Master asks:",
          do: %{"action" => "", "option_id" => "inn"},
          else: %{"action" => "I go over there.", "option_id" => nil}

      :intent, _user ->
        clarifying_intent()

      _kind, _user ->
        :default
    end)

    {:ok, run_id} = Runner.start("lotta", "tin_valley", turn_limit: 1)

    assert {:ok, %{status: "finished", stop_reason: "turn_limit"} = run} = await(run_id)
    assert_received {:persona_prompt, first}
    refute first =~ "The Game Master asks:"
    assert_received {:persona_prompt, question}
    assert question =~ "The Game Master asks: Which way?"
    assert question =~ ~s(option_id "inn": Ask the innkeeper)
    assert [%Turn{player_action: "Ask the innkeeper"}] = turns(run.game_session_id)
  end

  test "stops when the character is dead" do
    stub_llm(fn
      :persona, _user ->
        if turns_so_far() == 1, do: kill_character()
        %{"action" => "I charge the orcs.", "option_id" => nil}

      _kind, _user ->
        :default
    end)

    {:ok, run_id} = Runner.start("hawk", "tin_valley", turn_limit: 5)

    assert {:ok, %{status: "stopped", stop_reason: "dead", turns_played: 1}} = await(run_id)
  end

  test "the persona sees the story but no hidden events, GM notes or rolls" do
    test_pid = self()

    stub_llm(fn
      :persona, user ->
        send(test_pid, {:persona_prompt, user})
        hide_secret_event()
        %{"action" => "Evening! Are you not aware of the new regulations?", "option_id" => nil}

      _kind, _user ->
        :default
    end)

    {:ok, run_id} = Runner.start("paul", "tin_valley", turn_limit: 2)
    assert {:ok, %{status: "finished"} = run} = await(run_id)

    assert [%{payload: %{"gm_notes" => "SECRET-GM-NOTE"}} | _] =
             GMReasoning.list_for_session(run.game_session_id)

    assert Repo.exists?(from(e in SessionEvent, where: e.payload["text"] == "SECRET-EVENT"))

    assert_received {:persona_prompt, _first}
    assert_received {:persona_prompt, second}
    assert second =~ "The lamp gutters as the innkeeper eyes you."
    assert second =~ "Character: Elara Voss"
    refute second =~ "SECRET"
    refute second =~ ~r/roll|difficulty|gm_notes/i
  end

  defp await(run_id) do
    result = Runner.await(run_id, 10_000, 20)
    wait_until(fn -> Task.Supervisor.children(TalesForge.Playtest.Supervisor) == [] end)
    result
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("timed out waiting")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  defp turns(session_id) do
    Repo.all(from(t in Turn, where: t.game_session_id == ^session_id, order_by: t.turn_number))
  end

  defp turns_so_far, do: Repo.aggregate(Turn, :count)

  defp calls(session_id) do
    Repo.all(
      from(c in AICall, where: c.game_session_id == ^session_id, select: {c.purpose, c.status})
    )
  end

  defp kill_character do
    session = Repo.one!(from(s in GameSession, order_by: [desc: s.inserted_at], limit: 1))
    world = put_in(session.world_state, ["character", "vitality"], "dead")
    session |> GameSession.changeset(%{status: "dead", world_state: world}) |> Repo.update!()
  end

  defp hide_secret_event do
    session = Repo.one!(from(s in GameSession, order_by: [desc: s.inserted_at], limit: 1))

    %SessionEvent{}
    |> SessionEvent.changeset(%{
      game_session_id: session.id,
      kind: "npc_plan",
      actor: "innkeep",
      player_aware: false,
      tick: 1,
      payload: %{"text" => "SECRET-EVENT"}
    })
    |> Repo.insert!()
  end

  defp clarifying_intent do
    %{
      "overall_intent" => "go somewhere",
      "actions" => [
        %{
          "action_type" => "speak",
          "target" => "innkeep",
          "parameters" => %{"skill" => "persuasion"}
        },
        %{"action_type" => "move", "target" => "market_square", "parameters" => %{}}
      ],
      "primary_index" => 0,
      "confidence" => 0.4,
      "needs_clarification" => true,
      "clarification_question" => "Which way?",
      "clarification_options" => [
        %{"id" => "inn", "label" => "Ask the innkeeper", "action_index" => 0},
        %{"id" => "square", "label" => "Walk to the square", "action_index" => 1}
      ]
    }
  end

  # Answers every LLM call like xAI would, 2000 micro-USD each. `reply.(kind, user)`
  # returns the JSON for that call, or :default.
  defp stub_llm(reply) do
    Req.Test.stub(TalesForge.LLM, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"messages" => [%{"content" => system}, %{"content" => user}]} = Jason.decode!(body)
      kind = kind(system, user)

      content =
        case reply.(kind, user) do
          :default -> default_reply(kind)
          map -> map
        end

      Req.Test.json(conn, %{
        "choices" => [
          %{"message" => %{"role" => "assistant", "content" => Jason.encode!(content)}}
        ],
        "usage" => %{
          "prompt_tokens" => 2000,
          "completion_tokens" => 100,
          "cost_in_usd_ticks" => 20_000_000
        }
      })
    end)

    System.put_env("LLM_PROVIDER", "xai")
    System.put_env("XAI_API_KEY", "test-key")
  end

  defp kind(system, user) do
    cond do
      system =~ "You are a playtest bot" -> :persona
      user =~ "gm_notes" -> :gm
      user =~ "overall_intent" -> :intent
      true -> :scene
    end
  end

  defp default_reply(:persona), do: %{"action" => "I look around the inn.", "option_id" => nil}
  defp default_reply(:gm), do: @gm_reply

  defp default_reply(:scene),
    do: %{"location_name" => "Valley Inn", "narrative" => "Rain drums on the inn's shutters."}

  defp default_reply(:intent) do
    %{
      "overall_intent" => "look around",
      "actions" => [
        %{"action_type" => "observe", "target" => nil, "parameters" => %{"skill" => "insight"}}
      ],
      "primary_index" => 0,
      "confidence" => 0.95,
      "needs_clarification" => false
    }
  end

  defp put_caps(caps), do: Application.put_env(:ex_tales_forge, :ai_spend_caps, caps)
end
