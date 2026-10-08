defmodule TalesForge.Playtest.JevScorerTest do
  use TalesForge.DataCase, async: false

  import ExUnit.CaptureLog
  import TalesForge.PlaytestHelpers

  alias TalesForge.Jido
  alias TalesForge.Playtest.{AffectLevels, JevScorer, Reports, Runner, Scorer}
  alias TalesForge.Schemas.AICall

  setup do
    Application.put_env(:ex_tales_forge, :playtest_runner_enabled, true)
    Application.put_env(:jev, :api_key, "test")

    on_exit(fn ->
      for pid <- Task.Supervisor.children(TalesForge.Playtest.Supervisor),
          do: Task.Supervisor.terminate_child(TalesForge.Playtest.Supervisor, pid)

      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
      Application.delete_env(:ex_tales_forge, :playtest_runner_enabled)
      Application.put_env(:jev, :api_key, nil)
      System.put_env("LLM_PROVIDER", "mock")
      System.delete_env("XAI_API_KEY")
    end)

    :ok
  end

  defp finished_run(persona, opts \\ []) do
    stub_llm(fn _, _ -> :default end)

    {:ok, run_id} =
      Runner.start(persona, "tin_valley", Keyword.merge([turn_limit: 1, auto_score: false], opts))

    assert {:ok, run} = await(run_id)
    run
  end

  test "configured?/0 follows the api key" do
    assert JevScorer.configured?()
    Application.put_env(:jev, :api_key, nil)
    refute JevScorer.configured?()
  end

  test "build_state is player text and GM narration only — no gm_notes" do
    stub_llm(fn
      :gm, _ -> %{"narrative" => "VISIBLE-GM-NARRATION", "gm_notes" => "SECRET-GM-NOTE"}
      _, _ -> :default
    end)

    {:ok, run_id} = Runner.start("paul", "tin_valley", turn_limit: 1, auto_score: false)
    assert {:ok, run} = await(run_id)
    state = JevScorer.build_state(run)

    assert state.text =~ "VISIBLE-GM-NARRATION"
    assert state.text =~ "Player:" or state.text =~ "Opening"
    refute state.text =~ "SECRET-GM-NOTE"
    refute state.text =~ "gm_notes"
  end

  test "scale maps Jev 0-index to 1–5" do
    assert JevScorer.scale(0) == 1.0
    assert JevScorer.scale(3.4) == 4.4
    assert JevScorer.scale(4) == 5.0
    assert JevScorer.scale(nil) == nil
  end

  test "scores session and turns, persists confidence and probabilities" do
    run = finished_run("paul", turn_limit: 2)

    Req.Test.stub(Jev.HTTP, fn conn ->
      Jev.Test.respond(conn,
        persona_session_affect: 3.2,
        persona_turn_affect_1: 2.0,
        persona_turn_affect_2: 4.0,
        confidence: %{
          persona_session_affect: 0.81,
          persona_turn_affect_1: 0.7,
          persona_turn_affect_2: 0.9
        },
        model: "jev-1.13.0",
        usage: %{input_tokens: 500}
      )
    end)

    assert {:ok, session_score} = JevScorer.score(run.id)
    assert session_score.source == "jev"
    assert session_score.kind == "session_affect"
    assert session_score.overall == 4.2
    assert_in_delta session_score.confidence, 0.81, 0.001
    assert session_score.model == "jev-1.13.0"
    assert session_score.rubric_version =~ "jev-affect-v1-"

    turns = Reports.turn_affect_scores(run.id)
    assert Enum.map(turns, &{&1.turn_number, &1.overall}) == [{1, 3.0}, {2, 5.0}]

    assert Reports.latest_score(run.id).id == session_score.id

    # The Jev call is its own call type, timed, tagged with the run's adventure.
    assert %AICall{call_type: "jev", model: "jev-1.13.0", adventure_id: "tin_valley"} =
             call =
             Repo.get_by!(AICall, game_session_id: run.game_session_id, purpose: "scorer")

    assert call.latency_ms >= 0
    assert %DateTime{} = call.started_at

    # Run status (rpc / mix playtest.run) carries the call-type metrics.
    assert {:ok, %{metrics: metrics}} = Runner.status(run.id)
    assert metrics.turns == 2
    assert [%{turn: 1, steps_ms: steps}, %{turn: 2}] = metrics.per_turn
    assert Map.keys(steps) |> Enum.sort() == ~w(gm intent persist player_quote prompt rules)
  end

  test "Scorer.score prefers Jev when configured" do
    run = finished_run("hawk")

    Req.Test.stub(Jev.HTTP, fn conn ->
      Jev.Test.respond(conn,
        persona_session_affect: 1.0,
        persona_turn_affect_1: 1.0,
        confidence: %{persona_session_affect: 0.5, persona_turn_affect_1: 0.5},
        model: "jev-1.13.0"
      )
    end)

    assert {:ok, score} = Scorer.score(run.id)
    assert score.source == "jev"
    assert score.overall == 2.0
  end

  test "when key unset, Scorer falls back to LLM rubric" do
    Application.put_env(:jev, :api_key, nil)
    stub_llm(fn _, _ -> :default end)
    {:ok, run_id} = Runner.start("paul", "tin_valley", turn_limit: 1, auto_score: false)
    assert {:ok, run} = await(run_id)

    assert {:ok, score} = Scorer.score(run.id)
    assert score.source == "llm"
    assert score.kind == "rubric"
  end

  test "disabled when runner off" do
    Application.put_env(:ex_tales_forge, :playtest_runner_enabled, false)
    capture_log(fn -> assert {:error, :disabled} = JevScorer.score(Ecto.UUID.generate()) end)
  end

  test "affect levels exist for every persona" do
    for id <- AffectLevels.persona_ids() do
      assert length(AffectLevels.levels(id)) == 5
    end
  end
end
