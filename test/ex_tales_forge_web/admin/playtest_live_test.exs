defmodule TalesForgeWeb.AdminLive.PlaytestLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TalesForge.PlaytestHelpers

  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.Repo
  alias TalesForge.Schemas.{AICall, PlaytestRun, PlaytestScore, Scene, SessionEvent, Turn}

  setup %{conn: conn} do
    on_exit(fn ->
      for pid <- Task.Supervisor.children(TalesForge.Playtest.Supervisor),
          do: Task.Supervisor.terminate_child(TalesForge.Playtest.Supervisor, pid)

      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
      Application.delete_env(:ex_tales_forge, :playtest_runner_enabled)
    end)

    {:ok, conn: log_in_admin(conn)}
  end

  test "pages are admin only" do
    run = seed_run()

    for conn <- [build_conn(), log_in_admin(build_conn(), "stranger@example.com")],
        path <- [~p"/admin/playtest", ~p"/admin/playtest/#{run.id}"] do
      assert redirected_to(get(conn, path)) =~ "/admin/login"
    end
  end

  test "runs list shows game cost, persona cost, game time and score", %{conn: conn} do
    scored = seed_run(persona: "paul", score: true)
    seed_run(persona: "hawk")

    {:ok, _view, html} = live(conn, ~p"/admin/playtest")

    assert html =~ "Playtest runs"
    assert html =~ "paul"
    assert html =~ "hawk"
    assert html =~ "3.5/5"
    assert html =~ "12.3 s"
    # Game cost: gm + scene only; the persona's own cost is its own column.
    assert html =~ "$0.0150"
    assert html =~ "$0.0040"
    assert html =~ ~s(id="run-#{scored.id}")
  end

  test "start form is hidden and refused when the runner is off", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/playtest")
    refute html =~ "Start a run"

    assert render_hook(view, "start", %{
             "persona" => "paul",
             "module" => "tin_valley",
             "turn_limit" => "5"
           }) =~
             "Could not start the run: :disabled"

    assert Repo.aggregate(PlaytestRun, :count) == 0
  end

  test "start form starts a run when the runner is on", %{conn: conn} do
    Application.put_env(:ex_tales_forge, :playtest_runner_enabled, true)
    {:ok, view, html} = live(conn, ~p"/admin/playtest")
    assert html =~ "Start a run"

    view
    |> form("#start-run-form", %{
      "persona" => "lars",
      "module" => "tin_valley",
      "turn_limit" => "2"
    })
    |> render_submit()

    run = Repo.one!(PlaytestRun)
    assert_redirect(view, ~p"/admin/playtest/#{run.id}")
    assert %{persona: "lars", turn_limit: 2} = run
    await(run.id)
  end

  test "run detail shows turns side by side, costs by purpose, the persona line and the score", %{
    conn: conn
  } do
    run = seed_run(score: true, reasoning: true)

    opening =
      GameSessions.opening_scene(run.game_session_id) ||
        Repo.insert!(%Scene{
          game_session_id: run.game_session_id,
          location_id: "valley_inn",
          location_name: "Valley Inn",
          narrative: "Rain drums on the shutters of the Valley Inn."
        })

    {:ok, view, html} = live(conn, ~p"/admin/playtest/#{run.id}")

    # The GM's opening comes before turn 1, so the persona is seen responding to it.
    assert has_element?(view, "#turn-opening", "Opening · GM narration")
    assert view |> element("#turn-opening") |> render() =~ opening.location_name

    assert html =~ "I ask the innkeeper about the orcs."
    assert html =~ "Brenna wipes the bar and lowers her voice."
    assert html =~ "insight · d20 7 vs 9 · success"
    assert html =~ "Foreshadow the nest; Brenna is scared."
    assert html =~ "Game total"
    assert html =~ "$0.0150"
    assert html =~ "Persona (bot)"
    assert html =~ "$0.0040"
    assert html =~ "Scorer"
    assert html =~ "3.5/5"
    assert html =~ "1. Intent correctly inferred"
    assert html =~ "The bluff landed."
    assert html =~ "12.3 s"
    assert html =~ "Wall clock, incl. bot"
    assert html =~ ~p"/admin/sessions/#{run.game_session_id}"
    refute html =~ "Re-score"
  end

  test "run detail without score or reasoning, and scoring on demand", %{conn: conn} do
    run = seed_run()

    {:ok, _view, html} = live(conn, ~p"/admin/playtest/#{run.id}")
    assert html =~ "Not scored."
    assert html =~ "none recorded"
    refute html =~ ~s(phx-click="score")

    Application.put_env(:ex_tales_forge, :playtest_runner_enabled, true)
    {:ok, view, _html} = live(conn, ~p"/admin/playtest/#{run.id}")

    view |> element("button", "Score") |> render_click()
    html = render_async(view)

    assert html =~ "Scored."
    assert html =~ "No criterion could be scored"
    assert html =~ "Re-score"
    assert Repo.aggregate(PlaytestScore, :count) == 1
  end

  defp seed_run(opts \\ []) do
    {:ok, session} = GameSessions.create_session(%{name: "Seeded", adventure_id: "tin_valley"})

    run =
      Repo.insert!(%PlaytestRun{
        game_session_id: session.id,
        persona: Keyword.get(opts, :persona, "paul"),
        module: "tin_valley",
        build: "0.1.0",
        turn_limit: 5,
        turns_played: 1,
        status: "finished",
        stop_reason: "turn_limit",
        started_at: ~U[2026-10-06 15:00:00Z],
        finished_at: ~U[2026-10-06 15:00:20Z],
        game_ms: 12_300,
        persona_calls: 2,
        persona_ms: 3_100,
        persona_input_tokens: 4_000,
        persona_output_tokens: 120,
        persona_cost_micro_usd: 4_000
      })

    Repo.insert!(%Turn{
      game_session_id: session.id,
      turn_number: 1,
      player_action: "I ask the innkeeper about the orcs.",
      narrative: "Brenna wipes the bar and lowers her voice.",
      mechanical_resolution: %{
        "skill" => "insight",
        "roll" => 7,
        "effective_skill" => 9,
        "outcome" => "success"
      }
    })

    for {purpose, cost} <- [
          {"gm", 12_000},
          {"scene", 3_000},
          {"persona", 4_000},
          {"scorer", 2_500}
        ] do
      Repo.insert!(%AICall{
        game_session_id: session.id,
        purpose: purpose,
        model: "xai/grok-4.20-0309-non-reasoning",
        status: "ok",
        latency_ms: 1_500,
        input_tokens: 2_000,
        output_tokens: 60,
        cost_micro_usd: cost
      })
    end

    if opts[:reasoning] do
      Repo.insert!(%SessionEvent{
        game_session_id: session.id,
        kind: "gm_reasoning",
        actor: "gm",
        player_aware: false,
        tick: 1,
        payload: %{"turn_number" => 1, "gm_notes" => "Foreshadow the nest; Brenna is scared."}
      })
    end

    if opts[:score] do
      Repo.insert!(%PlaytestScore{
        playtest_run_id: run.id,
        model: "xai/grok-4.20-0309-non-reasoning",
        rubric_version: "v1-abc1234",
        scores: %{
          "1. Intent correctly inferred from in-character speech." => %{
            "score" => 4,
            "evidence" => "T1"
          },
          "2. NPC responds in character." => %{"score" => 3, "evidence" => "T1"}
        },
        overall: 3.5,
        rationale: "The bluff landed."
      })
    end

    run
  end
end
