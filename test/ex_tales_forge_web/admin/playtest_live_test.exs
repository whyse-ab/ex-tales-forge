defmodule TalesForgeWeb.AdminLive.PlaytestLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TalesForge.PlaytestHelpers

  import Ecto.Query

  alias TalesForge.GameSessions
  alias TalesForge.NPC
  alias TalesForge.Jido
  alias TalesForge.Repo

  alias TalesForge.Schemas.{
    AICall,
    GameSession,
    PlaytestRun,
    PlaytestScore,
    Scene,
    SessionEvent,
    Turn
  }

  setup %{conn: conn} do
    # Scoring here is the LLM rubric path: no TypeSafe key, whatever the shell exports.
    Application.put_env(:jev, :api_key, nil)

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

    for conn <- [build_conn(), log_in_non_member(build_conn())],
        path <- [~p"/admin/playtest", ~p"/admin/playtest/#{run.id}"] do
      assert redirected_to(get(conn, path)) =~ "/admin/login"
    end
  end

  test "the founder summary sits on top, the run details below, and only behind login",
       %{conn: conn} do
    run = seed_run(persona: "hawk")

    for anon <- [build_conn(), log_in_non_member(build_conn())] do
      conn = get(anon, ~p"/admin/playtest")
      assert redirected_to(conn) =~ "/admin/login"
      refute response(conn, 302) =~ "What we test, and how"
    end

    {:ok, view, html} = live(conn, ~p"/admin/playtest")

    assert has_element?(view, "#summary-intro h2", "What we test, and how")
    assert has_element?(view, "#summary-intro", "scale from 1 (frustrated) to 5")
    assert has_element?(view, "#summary-findings", "Hawk almost never meets danger")
    assert has_element?(view, "#run-details", "All runs, in detail")

    # Summary first, then the detailed runs.
    [summary_at, details_at, row_at] =
      for marker <- [~s(id="playtest-summary"), ~s(id="run-details"), ~s(id="run-#{run.id}")] do
        {at, _len} = :binary.match(html, marker)
        at
      end

    assert summary_at < details_at and details_at < row_at

    # Curated batches: date, commit, run count and per-persona numbers with
    # links to the best and worst runs.
    assert has_element?(view, "#batch-elara h3", "The Elara runs")
    assert has_element?(view, "#batch-elara-runs", "44 runs")
    assert has_element?(view, "#batch-elara-source", "numbers from the written analysis")
    assert has_element?(view, "#batch-baseline-2026-10-07-commit a", "2a6589e")
    assert has_element?(view, "#batch-baseline-2026-10-07-runs", "65 runs")
    assert has_element?(view, "#batch-baseline-2026-10-07-hawk", "3.02")
    assert has_element?(view, "#batch-baseline-2026-10-07-hawk", "100%")
    assert has_element?(view, "#batch-baseline-2026-10-07-ronny", "cheater test")

    # The curated runs are not on this server: their links open them on playtest.
    assert has_element?(
             view,
             ~s(#batch-baseline-2026-10-07-hawk a[href="https://tales-forge-playtest.fly.dev/admin/playtest/5dc4bfff-db85-42ad-8eba-5044246a427d"]),
             "4.86"
           )

    assert has_element?(view, "#batch-baseline-2026-10-07", "a lead by turn 2 in 98% of games")
    assert has_element?(view, "#batch-baseline-2026-10-07", "about $0.09 per game")

    # A finished batch that fell short of its plan says both counts, and shows
    # the curated numbers from its analysis when its runs aren't here.
    assert has_element?(
             view,
             "#batch-post-rework-2026-10-08-runs",
             "23 of 25 planned runs done"
           )

    assert has_element?(view, "#batch-post-rework-2026-10-08-hawk", "3.34")
    refute has_element?(view, "#batch-post-rework-2026-10-08", "No numbers yet")

    # The two arms of the intent comparison and the full batch of 2026-10-09.
    assert has_element?(view, "#batch-intent-compare-off-runs", "20 runs")
    assert has_element?(view, "#batch-intent-compare-on-runs", "20 runs")
    assert has_element?(view, "#batch-intent-compare-on-lotta", "3.19")
    assert has_element?(view, "#batch-full-2026-10-09-runs", "25 runs")
    assert has_element?(view, "#batch-full-2026-10-09-commit a", "dd5dc7e")
    assert has_element?(view, "#batch-full-2026-10-09-paul", "4.96")

    # Findings link to run pages on the playtest server (so they work on
    # production too), to the turn they talk about where they name one.
    assert has_element?(
             view,
             ~s(#summary-findings a[href="https://tales-forge-playtest.fly.dev/admin/playtest/761713eb-b3cd-4460-b4d0-34c7ba6f777c"])
           )

    assert has_element?(
             view,
             ~s(#summary-findings a[href="https://tales-forge-playtest.fly.dev/admin/playtest/72d7292e-5df7-4ffa-bd02-1277cc9d081c#turn-4"])
           )

    # The post-rework batch links its written analysis.
    assert has_element?(
             view,
             ~s(#batch-post-rework-2026-10-08 a[href$="analysis-jev-post-rework-2026-10-08.md"])
           )
  end

  test "a batch's numbers fill in live from its series runs on this server", %{conn: conn} do
    sha = "abcdef0123456789abcdef0123456789abcdef01"

    runs =
      for {persona, score} <- [{"hawk", 4.2}, {"hawk", 1.8}, {"lotta", 3.4}] do
        run =
          seed_run(
            persona: persona,
            git_sha: sha,
            notes: "series=post-rework-2026-10-08 variant=default"
          )

        Repo.insert!(%PlaytestScore{
          playtest_run_id: run.id,
          model: "jev-1.13.0",
          rubric_version: "jev-affect-v1-test",
          source: "jev",
          kind: "session_affect",
          overall: score,
          confidence: 0.8
        })

        run
      end

    {:ok, view, _html} = live(conn, ~p"/admin/playtest")

    batch = "#batch-post-rework-2026-10-08"
    assert has_element?(view, "#{batch}-runs", "3 of 25 planned runs done")
    assert has_element?(view, "#{batch}-source", "numbers live from the runs on this server")
    assert has_element?(view, "#{batch}-commit a", "abcdef0")
    assert has_element?(view, "#{batch}-hawk", "3.00")
    assert has_element?(view, "#{batch}-lotta", "3.40")
    # Paul has no live runs here: his row stays, without the curated numbers.
    assert has_element?(view, "#{batch}-paul")
    refute has_element?(view, "#{batch}-paul", "4.77")

    [best, worst | _] = runs
    assert has_element?(view, ~s(#{batch}-hawk a[href="/admin/playtest/#{best.id}"]), "4.20")
    assert has_element?(view, ~s(#{batch}-hawk a[href="/admin/playtest/#{worst.id}"]), "1.80")
  end

  test "a running batch counts up to its plan", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "summary-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "summary.md"), "Intro\n<!-- batches -->\nFindings")

    File.write!(
      Path.join(dir, "batches.json"),
      Jason.encode!(%{
        "batches" => [
          %{
            "id" => "next",
            "title" => "Next",
            "status" => "running",
            "series" => "next-1",
            "variant" => "default",
            "runs" => 25
          },
          %{
            "id" => "later",
            "title" => "Later",
            "status" => "running",
            "series" => "later-1",
            "runs" => 10
          }
        ]
      })
    )

    Application.put_env(:ex_tales_forge, :playtest_summary_dir, dir)

    on_exit(fn ->
      Application.delete_env(:ex_tales_forge, :playtest_summary_dir)
      File.rm_rf!(dir)
    end)

    seed_run(persona: "hawk", notes: "series=next-1 variant=default")

    {:ok, view, _html} = live(conn, ~p"/admin/playtest")

    assert has_element?(view, "#batch-next-runs", "1 of 25 runs done so far")
    assert has_element?(view, "#batch-later-runs", "10 runs planned")
    assert has_element?(view, "#batch-later", "No numbers yet")
  end

  test "the run list still shows when the summary files can't be read", %{conn: conn} do
    Application.put_env(:ex_tales_forge, :playtest_summary_dir, "/nonexistent/summary")
    on_exit(fn -> Application.delete_env(:ex_tales_forge, :playtest_summary_dir) end)
    run = seed_run()

    {:ok, view, _html} = live(conn, ~p"/admin/playtest")

    assert has_element?(view, "#playtest-summary-missing")
    refute has_element?(view, "#playtest-summary")
    assert has_element?(view, "#run-#{run.id}")
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

  test "runs list says how long ago each run started, newest first, Stockholm time on hover",
       %{conn: conn} do
    now = DateTime.utc_now(:second)
    old = seed_run(persona: "lotta", started_at: DateTime.add(now, -4 * 86_400, :second))
    recent = seed_run(persona: "paul", started_at: DateTime.add(now, -3 * 60, :second))
    middle = seed_run(persona: "hawk", started_at: DateTime.add(now, -2 * 3_600 - 60, :second))

    {:ok, view, html} = live(conn, ~p"/admin/playtest")

    # Order unchanged: newest started_at first, whatever the insert order.
    assert Regex.scan(~r/<tr id="run-([^"]+)"/, html, capture: :all_but_first) ==
             [[recent.id], [middle.id], [old.id]]

    assert has_element?(view, "#run-#{recent.id}-started", "3 minutes ago")
    assert has_element?(view, "#run-#{middle.id}-started", "2 hours ago")
    assert has_element?(view, "#run-#{old.id}-started", "4 days ago")

    title = TalesForgeWeb.TimeAgo.stockholm(recent.started_at)
    assert has_element?(view, ~s(#run-#{recent.id}-started[title="#{title}"]))
    assert html =~ TalesForgeWeb.TimeAgo.stockholm(recent.started_at, "%m-%d %H:%M")
    refute html =~ "UTC"

    # The minute tick re-renders without reloading or reordering the rows.
    send(view.pid, :tick)
    assert has_element?(view, "#run-#{recent.id}-started", "3 minutes ago")
  end

  test "run detail header says how long ago the run started and when, in Stockholm",
       %{conn: conn} do
    run =
      seed_run(
        score: true,
        started_at: DateTime.add(DateTime.utc_now(:second), -2 * 3_600, :second)
      )

    {:ok, view, html} = live(conn, ~p"/admin/playtest/#{run.id}")

    assert has_element?(view, "#run-started", "2 hours ago")
    assert html =~ "(#{TalesForgeWeb.TimeAgo.stockholm(run.started_at)})"
    assert has_element?(view, "#score-scored-at", "a few seconds ago")
    refute html =~ "UTC"

    send(view.pid, :tick)
    assert has_element?(view, "#run-started", "2 hours ago")
  end

  test "run detail and list show the commit and the flags the run was played under",
       %{conn: conn} do
    sha = "00c370d1a2b3c4d5e6f708192a3b4c5d6e7f8091"
    flags = %{"npc_reactions" => "on", "world_agents" => "off", "variant" => "default"}
    run = seed_run(git_sha: sha, flags: flags)
    bare = seed_run(persona: "lars")

    {:ok, view, _html} = live(conn, ~p"/admin/playtest/#{run.id}")

    assert has_element?(
             view,
             ~s(#run-commit a[href="https://github.com/whyse-ab/ex-tales-forge/commit/#{sha}"]),
             "00c370d"
           )

    assert has_element?(view, "#run-flags li", "npc_reactions=on")
    assert has_element?(view, "#run-flags li", "variant=default")

    {:ok, view, _html} = live(conn, ~p"/admin/playtest/#{bare.id}")
    assert has_element?(view, "#run-commit", "unknown")
    refute has_element?(view, "#run-flags")

    {:ok, _view, html} = live(conn, ~p"/admin/playtest")
    assert html =~ "00c370d"
    assert html =~ "default · reactions"
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

  test "run detail breaks cost down by call type, persona apart, with per-turn rows",
       %{conn: conn} do
    run = seed_run()
    {:ok, view, _html} = live(conn, ~p"/admin/playtest/#{run.id}")

    assert has_element?(view, "#run-breakdown-game-llm-gm", "$0.0120")
    assert has_element?(view, "#run-breakdown-game-function-turn_rules", "14 ms")
    assert has_element?(view, "#run-breakdown-scorer-jev-scorer", "$0.0025")
    # Game total: gm + scene; persona has its own block and line.
    assert has_element?(view, "#run-breakdown-game-total", "$0.0150")
    assert has_element?(view, "#run-breakdown-persona-llm-persona", "$0.0040")
    refute has_element?(view, "#run-breakdown-game #run-breakdown-persona-llm-persona")
    assert has_element?(view, "#persona-line", "$0.0040")

    assert has_element?(view, "#run-cache-gm-later", "—")
    assert has_element?(view, "#run-gm-latency", "1.50 s")
    assert has_element?(view, "#run-turn-1", "hit")
    assert has_element?(view, "#run-turn-1", "14 ms")
    assert has_element?(view, "#run-game-per-turn", "$0.0150")
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

  test "run detail shows Jev session affect and turn strip", %{conn: conn} do
    run = seed_run()

    Repo.insert!(%PlaytestScore{
      playtest_run_id: run.id,
      model: "jev-1.13.0",
      rubric_version: "jev-affect-v1-abc1234",
      source: "jev",
      kind: "session_affect",
      scores: %{"persona_session_affect" => %{"score" => 4.2, "confidence" => 0.81}},
      overall: 4.2,
      confidence: 0.81,
      probabilities: %{"3" => 0.6, "4" => 0.3}
    })

    Repo.insert!(%PlaytestScore{
      playtest_run_id: run.id,
      model: "jev-1.13.0",
      rubric_version: "jev-affect-v1-abc1234",
      source: "jev",
      kind: "turn_affect",
      turn_number: 1,
      scores: %{},
      overall: 3.0,
      confidence: 0.7,
      probabilities: %{}
    })

    insert_turn_affect(run, 2, 4.5, 0.9)
    insert_turn_affect(run, 3, 2.0, 0.2)

    {:ok, view, html} = live(conn, ~p"/admin/playtest/#{run.id}")

    assert html =~ "4.2/5 persona affect"
    assert html =~ "Jev session_affect"
    assert html =~ "jev-1.13.0"
    assert has_element?(view, "#score-confidence", "Session confidence 81.0%")
    assert has_element?(view, "#turn-affect-strip", "T1: 3.0")
    # Headline: confidence-weighted turn average, (3.0×0.7 + 4.5×0.9 + 2.0×0.2) / 1.8.
    assert has_element?(view, "#jev-headline", "3.64/5 · unsure 33%")
    assert has_element?(view, "#jev-headline", "confidence-weighted over 3 turns")
    assert has_element?(view, "#jev-breakdown", "1 high · 0 low · 1 middle · 1 unsure")
  end

  test "runs list shows the weighted Jev headline with the unsure share and the breakdown",
       %{conn: conn} do
    run = seed_run(persona: "lotta")
    insert_turn_affect(run, 1, 4.0, 0.8)
    insert_turn_affect(run, 2, 3.0, 0.4)
    # A re-score of turn 2: only the newest row per turn counts.
    insert_turn_affect(run, 2, 2.0, 0.8)
    unscored = seed_run(persona: "hawk")

    {:ok, view, _html} = live(conn, ~p"/admin/playtest")

    assert has_element?(view, "#run-#{run.id}-jev", "3.00/5 · unsure 0%")
    assert has_element?(view, "#run-#{run.id}", "1 high · 1 low · 0 middle · 0 unsure")
    refute has_element?(view, "#run-#{unscored.id}-jev")
  end

  test "run detail shows how each character changed, with links to the turns and the gaps",
       %{conn: conn} do
    run = seed_run(notes: "series=cc-1 variant=default")
    session = Repo.get!(GameSession, run.game_session_id)
    tick = session.world_state["world_tick"] + 1

    Repo.insert!(%SessionEvent{
      game_session_id: session.id,
      kind: "gm_reasoning",
      actor: "gm",
      player_aware: false,
      tick: tick,
      payload: %{
        "turn_number" => 1,
        "gm_reply" => %{
          "npc_memory_updates" => [
            %{"npc_id" => "innkeep", "summary" => "The stranger asked about the orcs."}
          ]
        }
      }
    })

    :ok = NPC.record_memory(session.id, "innkeep", "The stranger asked about the orcs.", tick)
    {:ok, _} = NPC.bump_relationship(session.id, "innkeep", 0.05)

    world =
      Map.put(session.world_state, "npc_moods", %{
        "innkeep" => %{
          "emotion" => "wary",
          "intensity" => 0.6,
          "stance" => "cool",
          "turn_number" => 1
        }
      })

    session |> GameSession.changeset(%{world_state: world}) |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/admin/playtest/#{run.id}")

    assert has_element?(view, "#character-changes h2", "Character changes")
    # The player character first, open; NPCs with a change before the rest.
    assert has_element?(view, "#character-changes details[open] summary", "player character")
    assert has_element?(view, "#cc-innkeep-summary", "1 memories added")
    assert has_element?(view, "#cc-innkeep-field-stance", "cool (turn 1)")
    assert has_element?(view, "#cc-innkeep-field-relationship", "0.05")
    assert has_element?(view, "#cc-innkeep-memories", "The stranger asked about the orcs.")
    assert has_element?(view, ~s(#cc-innkeep-memories a[href="#turn-1"]), "Turn 1")
    assert has_element?(view, "#cc-innkeep-not-tracked", "Feelings toward other NPCs")
    assert has_element?(view, "#cc-innkeep-not-tracked", "not tracked yet")
    assert has_element?(view, ~s(#cc-turn-1 a[href="#turn-1"]))
    assert has_element?(view, "#cc-turn-1", "GM: The stranger asked about the orcs.")
    assert has_element?(view, "#cc-notes", "only each NPC's latest reaction is kept")
    # The link target exists on the same page.
    assert has_element?(view, "#turn-1")

    {:ok, view, _html} = live(conn, ~p"/admin/playtest")
    assert has_element?(view, "#batch-character-changes", "cc-1 · default")
    assert has_element?(view, "#batch-character-changes", "100% (1/1")
    assert has_element?(view, "#batch-character-changes", "Memories / run")
  end

  test "run detail of a run with no characters says so", %{conn: conn} do
    run = seed_run()

    Repo.delete_all(
      from c in TalesForge.Schemas.Character, where: c.game_session_id == ^run.game_session_id
    )

    Repo.delete_all(
      from n in TalesForge.Schemas.NpcInstance, where: n.game_session_id == ^run.game_session_id
    )

    session = Repo.get!(GameSession, run.game_session_id)

    session
    |> GameSession.changeset(%{world_state: Map.delete(session.world_state, "character")})
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/admin/playtest/#{run.id}")
    assert has_element?(view, "#character-changes", "No characters recorded for this run.")
  end

  defp insert_turn_affect(run, turn_number, overall, confidence) do
    Repo.insert!(%PlaytestScore{
      playtest_run_id: run.id,
      model: "jev-1.13.0",
      rubric_version: "jev-affect-v1-abc1234",
      source: "jev",
      kind: "turn_affect",
      turn_number: turn_number,
      scores: %{},
      overall: overall,
      confidence: confidence,
      probabilities: %{}
    })
  end

  defp seed_run(opts \\ []) do
    started_at = Keyword.get(opts, :started_at, ~U[2026-10-06 15:00:00Z])
    {:ok, session} = GameSessions.create_session(%{name: "Seeded", adventure_id: "tin_valley"})

    run =
      Repo.insert!(%PlaytestRun{
        game_session_id: session.id,
        persona: Keyword.get(opts, :persona, "paul"),
        module: "tin_valley",
        build: "0.1.0",
        git_sha: Keyword.get(opts, :git_sha),
        flags: Keyword.get(opts, :flags, %{}),
        notes: Keyword.get(opts, :notes),
        turn_limit: 5,
        turns_played: 1,
        status: "finished",
        stop_reason: "turn_limit",
        started_at: started_at,
        finished_at: DateTime.add(started_at, 20, :second),
        game_ms: 12_300,
        persona_calls: 2,
        persona_ms: 3_100,
        persona_input_tokens: 4_000,
        persona_output_tokens: 120,
        persona_cost_micro_usd: 4_000,
        notes: Keyword.get(opts, :notes)
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

    for {purpose, cost, turn, cached} <- [
          {"gm", 12_000, 1, 1_536},
          {"scene", 3_000, nil, 128},
          {"persona", 4_000, 1, 128},
          {"scorer", 2_500, nil, nil}
        ] do
      Repo.insert!(%AICall{
        game_session_id: session.id,
        purpose: purpose,
        call_type: if(purpose == "scorer", do: "jev", else: "llm"),
        model: "xai/grok-4.20-0309-non-reasoning",
        status: "ok",
        turn_number: turn,
        latency_ms: 1_500,
        input_tokens: 2_000,
        cached_tokens: cached,
        output_tokens: 60,
        cost_micro_usd: cost
      })
    end

    Repo.insert!(%AICall{
      game_session_id: session.id,
      purpose: "turn.rules",
      call_type: "function",
      model: "elixir",
      status: "ok",
      turn_number: 1,
      latency_ms: 14,
      cost_micro_usd: 0,
      cost_source: "free"
    })

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
