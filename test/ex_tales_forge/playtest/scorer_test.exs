defmodule TalesForge.Playtest.ScorerTest do
  use TalesForge.DataCase, async: false

  import ExUnit.CaptureLog
  import TalesForge.PlaytestHelpers

  alias TalesForge.Jido
  alias TalesForge.Playtest.{Reports, Runner, Scorer}
  alias TalesForge.Schemas.{AICall, PlaytestScore}

  setup do
    Application.put_env(:ex_tales_forge, :playtest_runner_enabled, true)

    on_exit(fn ->
      for pid <- Task.Supervisor.children(TalesForge.Playtest.Supervisor),
          do: Task.Supervisor.terminate_child(TalesForge.Playtest.Supervisor, pid)

      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
      System.put_env("LLM_PROVIDER", "mock")
      System.delete_env("XAI_API_KEY")
      Application.delete_env(:ex_tales_forge, :playtest_runner_enabled)
    end)

    :ok
  end

  test "a finished run is scored against the persona's scorecard and recorded in ai_calls" do
    test_pid = self()

    stub_llm(fn
      :scorer, user ->
        send(test_pid, {:judge_prompt, user})
        :default

      :persona, _user ->
        %{"action" => "Evening! Are you not aware of the new regulations?", "option_id" => nil}

      _kind, _user ->
        :default
    end)

    {:ok, run_id} = Runner.start("paul", "tin_valley", turn_limit: 1)
    assert {:ok, %{status: "finished", game_session_id: session_id}} = await(run_id)

    assert %PlaytestScore{} = score = Reports.latest_score(run_id)
    assert score.model == "xai/grok-4.20-0309-non-reasoning"
    assert score.rubric_version =~ ~r/^v1-[0-9a-f]{7}$/
    assert score.rationale =~ "bluff barely mattered"

    assert score.scores == %{
             "1. Intent correctly inferred from in-character speech." => %{
               "score" => 4,
               "evidence" => ~s(T1: "Evening!")
             },
             "2. No mechanics leaked into narration when rolls are hidden." => %{
               "score" => nil,
               "evidence" => "no rolls happened"
             },
             "3. NPC responds in character." => %{
               "score" => 2,
               "evidence" => "T1: the innkeeper eyes you"
             },
             "4. Quality of the bluff affects the outcome." => %{
               "score" => nil,
               "evidence" => "out of range"
             }
           }

    assert score.overall == 3.0

    assert %AICall{status: "ok", cost_micro_usd: 2_000} =
             Repo.get_by(AICall, game_session_id: session_id, purpose: "scorer")

    assert_received {:judge_prompt, prompt}
    assert prompt =~ "## Paul (role playing)"
    assert prompt =~ "1. Intent correctly inferred from in-character speech."
    assert prompt =~ "[Scene] Rain drums on the inn's shutters."
    assert prompt =~ "T1 [Player] Evening! Are you not aware of the new regulations?"
    assert prompt =~ "T1 [GM] The lamp gutters as the innkeeper eyes you."
    assert prompt =~ "T1 (GM notes) SECRET-GM-NOTE"
    assert prompt =~ "stopped by turn_limit"

    assert {:ok, _again} = Scorer.score(run_id)
    assert Repo.aggregate(PlaytestScore, :count) == 2
  end

  test "a scoring failure leaves the run finished and unscored" do
    stub_llm(fn
      :scorer, _user -> {:raw, "I would rather not say."}
      _kind, _user -> :default
    end)

    log =
      capture_log(fn ->
        {:ok, run_id} = Runner.start("hawk", "tin_valley", turn_limit: 1)
        assert {:ok, %{status: "finished", stop_reason: "turn_limit"}} = await(run_id)
        assert Reports.latest_score(run_id) == nil
      end)

    assert log =~ "playtest scoring failed"
    assert Repo.aggregate(PlaytestScore, :count) == 0
  end

  test "scores only finished or stopped runs, and only when enabled" do
    {:ok, run_id} = Runner.start("lotta", "tin_valley", turn_limit: 1)
    assert {:ok, _run} = await(run_id)
    # The mock judge scores nothing.
    assert %PlaytestScore{overall: nil, rationale: "Mock judge" <> _} =
             Reports.latest_score(run_id)

    Repo.update_all(TalesForge.Schemas.PlaytestRun, set: [status: "failed"])
    capture_log(fn -> assert {:error, {:not_scoreable, "failed"}} = Scorer.score(run_id) end)

    capture_log(fn -> assert {:error, :not_found} = Scorer.score(Ecto.UUID.generate()) end)

    Application.put_env(:ex_tales_forge, :playtest_runner_enabled, false)
    capture_log(fn -> assert {:error, :disabled} = Scorer.score(run_id) end)
  end
end
