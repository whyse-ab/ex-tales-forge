defmodule TalesForge.Playtest.RunnerTest do
  use TalesForge.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import TalesForge.PlaytestHelpers

  alias TalesForge.GameSessions
  alias TalesForge.GMReasoning
  alias TalesForge.Jido
  alias TalesForge.Playtest.Runner
  alias TalesForge.Schemas.{AICall, GameSession, Scene, SessionEvent, Turn}

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

  test "plays to the turn limit and records the run, its commit and flags" do
    System.put_env("GIT_SHA", "abc1234def")
    on_exit(fn -> System.delete_env("GIT_SHA") end)
    {:ok, run_id} = Runner.start("paul", "tin_valley", turn_limit: 2, notes: "smoke")

    assert {:ok, run} = await(run_id)
    assert %{status: "finished", stop_reason: "turn_limit", turns_played: 2, turn_limit: 2} = run
    assert %{persona: "paul", module: "tin_valley", notes: "smoke"} = run
    assert run.build =~ "0.1.0"
    assert run.git_sha == "abc1234def"

    assert %{
             "npc_reactions" => "off",
             "world_agents" => "off",
             "variant" => "default",
             "llm_provider" => "mock",
             "jev_rubric" => "jev-affect-v1-" <> _
           } = run.flags

    assert run.finished_at
    assert turns(run.game_session_id) |> length() == 2

    # skill growth is stored on the run when it ends
    stored = Repo.get!(TalesForge.Schemas.PlaytestRun, run_id).growth
    assert %{"skills" => _, "rolls" => _, "lp_gained" => _, "improvements" => _} = stored
    assert run.growth == stored
    assert stored == TalesForge.Playtest.Growth.for_session(run.game_session_id)
  end

  test "plays the requested behaviour variant, so both comparison arms share a deploy" do
    {:ok, run_id} = Runner.start("paul", "tin_valley", turn_limit: 1, variant: "baseline")

    assert {:ok, run} = await(run_id)
    assert Repo.get!(GameSession, run.game_session_id).world_state["variant"] == "baseline"
    assert Runner.start("paul", "tin_valley", variant: "nope") == {:error, :unknown_variant}
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

  test "the session cap counts only the game, not the persona" do
    # Scene 2000 + GM 2000 reach the 4000 cap after turn 1; the persona's 2000s don't count.
    put_caps(session_micro_usd: 4_000)
    stub_llm(fn _kind, _user -> :default end)

    {:ok, run_id} = Runner.start("lars", "tin_valley")

    assert {:ok, %{status: "stopped", stop_reason: "spend_cap", turns_played: 1} = run} =
             await(run_id)

    calls = calls(run.game_session_id)
    assert Enum.count(calls, &(&1 == {"persona", "ok"})) == 2
    assert {"gm", "capped"} in calls
    refute {"persona", "capped"} in calls
    assert {:ok, %{game_cost_usd: 0.004}} = Runner.status(run_id)
  end

  test "the persona's own per-run cap stops the run" do
    put_caps(persona_run_micro_usd: 3_000)
    stub_llm(fn _kind, _user -> :default end)

    {result, log} =
      with_log(fn ->
        {:ok, run_id} = Runner.start("ronny", "tin_valley", turn_limit: 5)
        await(run_id)
      end)

    assert {:ok, %{status: "stopped", stop_reason: "persona_cap", turns_played: 2} = run} = result
    assert log =~ "llm spend cap hit cap=persona_run"

    assert %{persona_calls: 3, persona_cost_micro_usd: 4_000} = run
    assert {"persona", "capped"} in calls(run.game_session_id)
  end

  test "stores persona totals apart from the game, and game time without the bot's thinking" do
    stub_llm(fn
      :persona, _user ->
        Process.sleep(600)
        :default

      :gm, _user ->
        Process.sleep(100)
        :default

      _kind, _user ->
        :default
    end)

    {:ok, run_id} = Runner.start("paul", "tin_valley", turn_limit: 1)
    assert {:ok, run} = await(run_id)

    assert %{persona_calls: 1, persona_input_tokens: 2000, persona_output_tokens: 100} = run
    assert run.persona_cost_micro_usd == 2_000
    assert run.persona_ms >= 600
    assert run.game_ms >= 100
    assert run.game_ms < 600
    # Opening scene and GM turn only; the persona's call and the scorer's are separate.
    assert run.game_cost_usd == 0.004
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

  test "each persona plays the character it created, and knows who it made" do
    test_pid = self()

    stub_llm(fn
      :persona, _user, system ->
        send(test_pid, {:persona_system, system})
        %{"action" => "I nod to the innkeeper.", "option_id" => nil}

      _kind, _user, _system ->
        :default
    end)

    {:ok, run_id} = Runner.start("lotta", "tin_valley", turn_limit: 1)
    assert {:ok, %{status: "finished"} = run} = await(run_id)

    character = Repo.get!(GameSession, run.game_session_id).world_state["character"]
    assert %{"name" => "Hilde Stonebrook", "race" => "dwarf", "class" => "druid"} = character
    assert character["stats"]["WIS"] == 15

    assert_received {:persona_system, system}
    assert system =~ "You created this character yourself: Hilde Stonebrook, a dwarf druid."
  end

  test "character: :default keeps the pack's default character and a plain persona prompt" do
    test_pid = self()

    stub_llm(fn
      :persona, _user, system ->
        send(test_pid, {:persona_system, system})
        %{"action" => "I nod to the innkeeper.", "option_id" => nil}

      _kind, _user, _system ->
        :default
    end)

    {:ok, run_id} = Runner.start("lotta", "tin_valley", turn_limit: 1, character: :default)
    assert {:ok, %{status: "finished"} = run} = await(run_id)

    assert %{"name" => "Elara Voss"} =
             Repo.get!(GameSession, run.game_session_id).world_state["character"]

    assert_received {:persona_system, system}
    refute system =~ "You created this character"
    {:ok, lotta} = TalesForge.Playtest.Personas.fetch("lotta")
    assert system == TalesForge.Playtest.Personas.system_prompt(lotta)
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
    assert second =~ "Character: Corvin Ashdown"
    refute second =~ "SECRET"
    refute second =~ ~r/roll|difficulty|gm_notes/i
  end

  test "the GM opens the scene before the persona's first move, and the persona sees it first" do
    test_pid = self()
    opening = "OPENING: Rain drums on the Valley Inn's shutters; the innkeeper looks up."

    stub_llm(fn
      :scene, _user ->
        send(test_pid, {:llm, :scene})
        %{"location_name" => "Valley Inn", "narrative" => opening}

      :persona, user ->
        scene_exists = Repo.exists?(from(s in Scene, where: s.narrative == ^opening))
        send(test_pid, {:llm, :persona, user, scene_exists})
        :default

      _kind, _user ->
        :default
    end)

    {:ok, run_id} = Runner.start("paul", "tin_valley", turn_limit: 1)
    assert {:ok, %{status: "finished"}} = await(run_id)

    assert_received {:llm, :scene}
    assert_received {:llm, :persona, first_prompt, true}
    # The opening is the first thing the persona reads, before the turn and panels.
    assert String.starts_with?(first_prompt, "The Game Master opens the scene:")
    assert first_prompt =~ opening
    refute_received {:llm, :persona, _, false}
  end

  test "without an opening scene the persona never moves" do
    test_pid = self()

    stub_llm(fn
      :scene, _user ->
        {:raw, "not json"}

      :persona, _user ->
        send(test_pid, :persona_called)
        :default

      _kind, _user ->
        :default
    end)

    {result, _log} =
      with_log(fn ->
        {:ok, run_id} = Runner.start("paul", "tin_valley", turn_limit: 1, turn_timeout_ms: 300)
        await(run_id)
      end)

    # The scene job keeps failing, so the run ends (timeout or error) with no move.
    assert {:ok, %{status: status, turns_played: 0} = run} = result
    assert status in ["stopped", "failed"]
    assert GameSessions.opening_scene(run.game_session_id) == nil
    refute_received :persona_called
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

  describe "a stale turn_completed (double turn 2)" do
    # Turn 1 was settled by the database poll; its own broadcast lands after,
    # while the runner already waits for turn 2. Taking it as turn 2's
    # completion made the persona move again with turn 2 still running, so
    # turn 2 was narrated twice (one copy failed on the unique turn number).
    setup do
      {:ok, session} = GameSessions.create_session(%{name: "Stale", adventure_id: "tin_valley"})
      insert_turn(session.id, 1)
      %{state: %{run: %{game_session_id: session.id}, timeout_ms: 200}, session: session}
    end

    test "is ignored, so the runner keeps waiting for turn 2", %{state: state} do
      send(self(), {:turn_completed, %{turn_count: 1, session_status: "active"}})
      assert Runner.await_event(state, {:turn, 1}) == :timeout
    end

    test "turn 2's own event still completes it", %{state: state} do
      send(self(), {:turn_completed, %{turn_count: 1, session_status: "active"}})
      send(self(), {:turn_completed, %{turn_count: 2, session_status: "active"}})
      assert {:completed, %{turn_count: 2}} = Runner.await_event(state, {:turn, 1})
    end

    test "an event without a turn number counts once the turn is stored", %{
      state: state,
      session: session
    } do
      send(self(), {:turn_completed, %{session_status: "active"}})
      assert Runner.await_event(state, {:turn, 1}) == :timeout

      insert_turn(session.id, 2)
      send(self(), {:turn_completed, %{session_status: "active"}})
      assert {:completed, _} = Runner.await_event(state, {:turn, 1})
    end
  end

  defp insert_turn(session_id, n) do
    Repo.insert!(%Turn{
      game_session_id: session_id,
      turn_number: n,
      player_action: "look",
      narrative: "Turn #{n}."
    })
  end
end
