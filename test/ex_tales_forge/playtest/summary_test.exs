defmodule TalesForge.Playtest.SummaryTest do
  use TalesForge.DataCase, async: true

  alias TalesForge.GameSessions
  alias TalesForge.Playtest.Summary
  alias TalesForge.Schemas.{AICall, PlaytestRun, PlaytestScore}

  doctest Summary

  @run_link ~r{/admin/playtest/([0-9a-f-]+)}

  # The shipped files, by path: the page tests may point the app env elsewhere.
  @shipped Application.app_dir(:ex_tales_forge, "priv/playtest/summary")

  describe "the shipped summary files" do
    test "load, in page order, with an intro, findings and the known batches" do
      assert {:ok, summary} = Summary.load(@shipped)

      assert summary.intro =~ "What we test, and how"
      assert summary.findings =~ "What we've learned so far"
      refute summary.intro =~ "<!-- batches -->"

      ids = Enum.map(summary.batches, & &1.id)
      assert ["elara", "baseline-2026-10-07" | _] = ids
      assert ids == Enum.uniq(ids)

      baseline = Enum.find(summary.batches, &(&1.id == "baseline-2026-10-07"))
      assert baseline.commit =~ ~r/^2a6589e/
      assert baseline.series == "baseline-2026-10-07"
      assert baseline.runs == 65
      assert baseline.source == :curated
      assert Enum.map(baseline.personas, &elem(&1, 0)) == ~w(paul lotta lars hawk ronny)

      {"hawk", hawk} = Enum.find(baseline.personas, &(elem(&1, 0) == "hawk"))
      assert hawk.mean == 3.02
      assert hawk.runs == 13
    end

    test "every run link and best or worst run is a run id" do
      {:ok, summary} = Summary.load(@shipped)

      linked =
        Regex.scan(@run_link, summary.intro <> summary.findings, capture: :all_but_first)
        |> List.flatten()

      picked =
        for batch <- summary.batches,
            {_persona, stats} <- batch.personas,
            id <- [stats.best, stats.worst],
            id != nil,
            do: id

      assert linked != [] and picked != []
      for id <- linked ++ picked, do: assert({:ok, ^id} = Ecto.UUID.cast(id))
    end

    test "every batch says what the game was like and what changed" do
      {:ok, summary} = Summary.load(@shipped)

      for batch <- summary.batches do
        assert is_binary(batch.title) and is_binary(batch.date), batch.id
        assert is_binary(batch.game) and is_binary(batch.changes), batch.id
      end
    end
  end

  describe "load/1 with broken files" do
    setup do
      dir = Path.join(System.tmp_dir!(), "summary-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "a missing file is an error", %{dir: dir} do
      assert {:error, :enoent} = Summary.load(dir)
    end

    test "batches.json must be valid JSON with a batches list", %{dir: dir} do
      File.write!(Path.join(dir, "summary.md"), "Intro only")

      File.write!(Path.join(dir, "batches.json"), "{nope")
      assert {:error, %Jason.DecodeError{}} = Summary.load(dir)

      File.write!(Path.join(dir, "batches.json"), ~s({"batches": {}}))
      assert {:error, :invalid_batches} = Summary.load(dir)

      File.write!(Path.join(dir, "batches.json"), ~s({"batches": [{"id": "x"}]}))

      assert {:ok, %{intro: "Intro only", findings: "", batches: [batch]}} = Summary.load(dir)
      assert %{id: "x", title: "x", personas: [], source: :curated} = batch
      assert batch.overall == %{hook_by_turn_2: nil, brush_off: nil, cost_per_run_usd: nil}
    end

    test "unknown personas come after the known ones; non-numbers become nil", %{dir: dir} do
      File.write!(Path.join(dir, "summary.md"), "A\n<!-- batches -->\nB")

      File.write!(
        Path.join(dir, "batches.json"),
        Jason.encode!(%{
          "batches" => [
            %{
              "id" => "b",
              "personas" => %{
                "zed" => %{"mean" => 3},
                "hawk" => %{"mean" => "high"},
                "paul" => %{}
              }
            }
          ]
        })
      )

      assert {:ok, %{batches: [%{personas: personas}]}} = Summary.load(dir)
      assert Enum.map(personas, &elem(&1, 0)) == ~w(paul hawk zed)
      assert {"hawk", %{mean: nil}} = Enum.at(personas, 1)
      assert {"zed", %{mean: 3}} = Enum.at(personas, 2)
    end
  end

  describe "live numbers" do
    test "live_stats/2 counts the series' done runs and their first Jev session score" do
      a = seed("s1", "default", "hawk", score: [2.0, 4.9], gm: 50_000, persona: 10_000)
      b = seed("s1", "default", "hawk", score: [4.0], gm: 70_000, persona: 10_000)
      dead = seed("s1", "default", "lars", status: "stopped", stop_reason: "dead", score: [1.5])

      # Not done, other series, other variant, and a look-alike name: all left out.
      seed("s1", "default", "hawk", status: "failed", score: [5.0])
      seed("s2", "default", "hawk", score: [5.0])
      seed("s1", "baseline", "hawk", score: [5.0])
      seed("s1x", "default", "hawk", score: [5.0])

      live = Summary.live_stats("s1", "default")

      assert live.runs == 3
      assert live.commit == "abc1234def"
      assert %DateTime{} = live.started_at

      hawk = live.personas["hawk"]
      assert hawk.runs == 2
      # First scoring pass only: a's re-score (4.9) does not count.
      assert hawk.mean == 3.0
      assert {hawk.best, hawk.best_score} == {b.id, 4.0}
      assert {hawk.worst, hawk.worst_score} == {a.id, 2.0}
      # gm + persona per run; the scorer is a bot call and left out.
      assert_in_delta hawk.cost_per_run_usd, 0.07, 1.0e-9

      assert live.personas["lars"].worst == dead.id
      assert Map.keys(live.personas) |> Enum.sort() == ~w(hawk lars)
    end

    test "live_stats/2 without a variant takes every variant; unscored runs still count" do
      seed("s3", "default", "paul", score: [4.0])
      seed("s3", "baseline", "paul", score: [])

      live = Summary.live_stats("s3")
      assert live.runs == 2
      assert live.personas["paul"].runs == 2
      assert live.personas["paul"].mean == 4.0

      assert %{runs: 0, commit: nil, started_at: nil, cost_per_run_usd: nil, personas: %{}} =
               Summary.live_stats("nothing-here")
    end

    test "with_live/1 swaps in live numbers and keeps the curated rates" do
      run = seed("live-1", "default", "hawk", score: [4.5], gm: 90_000, persona: 10_000)

      curated = %{
        id: "live-1",
        title: "Live",
        date: nil,
        commit: nil,
        commit_note: "to come",
        series: "live-1",
        variant: nil,
        runs: 25,
        planned_runs: 25,
        analysis: nil,
        game: "g",
        changes: "c",
        notes: nil,
        overall: %{hook_by_turn_2: 0.9, brush_off: 0.1, cost_per_run_usd: 1.0},
        personas: [
          {"paul",
           %{
             runs: 13,
             mean: 4.6,
             best: nil,
             best_score: nil,
             worst: nil,
             worst_score: nil,
             hook_by_turn_2: 1.0,
             brush_off: 0.0,
             cost_per_run_usd: 0.1
           }},
          {"hawk",
           %{
             runs: 13,
             mean: 1.0,
             best: nil,
             best_score: nil,
             worst: nil,
             worst_score: nil,
             hook_by_turn_2: 0.5,
             brush_off: 0.2,
             cost_per_run_usd: 0.1
           }}
        ],
        source: :curated
      }

      offline = %{curated | id: "offline", series: nil}
      empty = %{curated | id: "empty", series: "no-runs-yet"}

      assert [live, ^offline, ^empty] = Summary.with_live([curated, offline, empty])

      assert live.source == :live
      assert live.runs == 1
      assert live.planned_runs == 25
      assert live.commit == "abc1234def"
      assert live.date =~ ~r/^\d{4}-\d{2}-\d{2}$/
      assert_in_delta live.overall.cost_per_run_usd, 0.1, 1.0e-9
      assert live.overall.hook_by_turn_2 == 0.9

      assert [{"paul", paul}, {"hawk", hawk}] = live.personas
      # Not played live yet: no curated numbers pretending to be live.
      assert %{runs: 0, mean: nil, best: nil} = paul
      assert paul.hook_by_turn_2 == 1.0
      assert %{runs: 1, mean: 4.5, best: best, hook_by_turn_2: 0.5} = hawk
      assert best == run.id
    end
  end

  defp seed(series, variant, persona, opts) do
    {:ok, session} = GameSessions.create_session(%{name: "Seeded", adventure_id: "tin_valley"})
    started_at = ~U[2026-10-07 17:30:00Z]

    run =
      Repo.insert!(%PlaytestRun{
        game_session_id: session.id,
        persona: persona,
        module: "tin_valley",
        git_sha: "abc1234def",
        notes: "series=#{series} variant=#{variant} · extra",
        turn_limit: 10,
        turns_played: 10,
        status: Keyword.get(opts, :status, "finished"),
        stop_reason: Keyword.get(opts, :stop_reason, "turn_limit"),
        started_at: started_at,
        persona_cost_micro_usd: Keyword.get(opts, :persona, 0)
      })

    for {overall, i} <- Enum.with_index(Keyword.get(opts, :score, [])) do
      Repo.insert!(%PlaytestScore{
        playtest_run_id: run.id,
        model: "jev-1.13.0",
        rubric_version: "jev-affect-v1-test",
        source: "jev",
        kind: "session_affect",
        overall: overall,
        inserted_at: DateTime.add(~U[2026-10-07 18:00:00.000000Z], i, :second)
      })
    end

    for {purpose, cost} <- [{"gm", Keyword.get(opts, :gm, 0)}, {"scorer", 5_000}] do
      Repo.insert!(%AICall{
        game_session_id: session.id,
        purpose: purpose,
        call_type: "llm",
        model: "test",
        status: "ok",
        latency_ms: 1_000,
        cost_micro_usd: cost
      })
    end

    run
  end
end
