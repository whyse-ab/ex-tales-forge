defmodule TalesForge.Costs.PlaytestRunsTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.Costs.PlaytestRuns
  alias TalesForge.GameSessions
  alias TalesForge.Schemas.AICall
  alias TalesForge.Schemas.PlaytestRun

  doctest TalesForge.Costs.PlaytestRuns

  # 2026-10-15 12:00 in Stockholm (CEST): day starts 2026-10-14 22:00Z,
  # month starts 2026-09-30 22:00Z.
  @now ~U[2026-10-15 10:00:00Z]
  @today ~U[2026-10-15 09:00:00Z]

  setup do
    on_exit(fn -> Application.delete_env(:ex_tales_forge, :app_name) end)
    :ok
  end

  describe "spend/2: only playtest-run calls, split per line" do
    test "run calls go to their line; manual play and session-less calls are outside_runs" do
      run_session = run!(~U[2026-10-15 08:00:00Z])
      {:ok, manual} = GameSessions.create_session(%{name: "Manual play"})

      insert!("gm", 1_000, session: run_session)
      insert!("gm", 2_000, session: run_session, status: "error")
      insert!("intent_shadow", 30, session: run_session, call_type: "jev")
      insert!("intent", 40, session: run_session, call_type: "jev")
      insert!("intent", 500, session: run_session, call_type: "llm")
      insert!("scene", 600, session: run_session)
      insert!("npc_reaction", 7, session: run_session, call_type: "jev")
      insert!("persona", 9_000, session: run_session)
      insert!("persona", 0, session: run_session, status: "capped")
      insert!("scorer", 11, session: run_session, call_type: "jev")
      # Free Elixir steps are not calls.
      insert!("turn.prompt", 0, session: run_session, call_type: "function", model: "elixir")

      # Not a playtest run: manual play and a call without a session.
      insert!("gm", 100_000, session: manual)
      insert!("intent_shadow", 50, session: manual, call_type: "jev")
      insert!("gm", 200_000)

      {lines, outside} = PlaytestRuns.spend(~U[2026-10-15 00:00:00Z], @now)

      assert lines["gm"] == counts(2, 3_000, 0, 1)
      assert lines["jev_intent"] == counts(2, 70)
      assert lines["other_game"] == counts(3, 1_107)
      assert lines["persona"] == counts(2, 9_000, 1, 0)
      assert lines["jev_scoring"] == counts(1, 11)
      assert outside == counts(3, 300_050)
    end

    test "every line is present, zeroed, when nothing ran" do
      {lines, outside} = PlaytestRuns.spend(~U[2026-10-15 00:00:00Z], @now)
      assert Map.keys(lines) |> Enum.sort() == Enum.sort(PlaytestRuns.lines())
      assert Enum.all?(Map.values(lines), &(&1 == counts(0, 0)))
      assert outside == counts(0, 0)
    end
  end

  describe "summary/1" do
    test "today and month windows, game and bot subtotals, runs counted" do
      Application.put_env(:ex_tales_forge, :app_name, "tales-forge-playtest")
      run_session = run!(~U[2026-10-02 08:00:00Z])
      _other_run = run!(~U[2026-09-20 08:00:00Z])

      insert!("gm", 1_000, session: run_session)
      insert!("persona", 300, session: run_session)
      insert!("gm", 5_000, session: run_session, at: ~U[2026-10-02 09:00:00Z])
      insert!("scorer", 20, session: run_session, call_type: "jev", at: ~U[2026-10-02 09:00:00Z])
      # Last month and after now: left out.
      insert!("gm", 70_000, session: run_session, at: ~U[2026-09-30 21:59:59Z])
      insert!("gm", 80_000, session: run_session, at: ~U[2026-10-15 10:00:01Z])
      # Manual play: on its own line.
      insert!("gm", 400)

      summary = PlaytestRuns.summary(@now)

      assert summary["app"] == "tales-forge-playtest"
      assert summary["today"]["since"] == "2026-10-14T22:00:00Z"
      assert summary["today"]["game_micro_usd"] == 1_000
      assert summary["today"]["bots_micro_usd"] == 300
      assert summary["today"]["runs_total_micro_usd"] == 1_300
      assert summary["today"]["outside_runs"]["cost_micro_usd"] == 400

      month = summary["month"]
      assert month["since"] == "2026-09-30T22:00:00Z"
      assert month["game_micro_usd"] == 6_000
      assert month["bots_micro_usd"] == 320
      assert month["runs_total_micro_usd"] == 6_320
      assert month["runs"] == 1
      assert PlaytestRuns.month_all_micro_usd(summary) == 6_720
    end
  end

  describe "normalize/1 (what production accepts from playtest)" do
    test "round-trips through JSON and drops unknown keys" do
      run_session = run!(~U[2026-10-15 08:00:00Z])
      insert!("gm", 42, session: run_session)
      summary = PlaytestRuns.summary(@now)

      decoded =
        summary
        |> Map.put("extra", "dropped")
        |> put_in(["month", "lines", "gm", "prompt"], "dropped")
        |> Jason.encode!()
        |> Jason.decode!()

      assert {:ok, ^summary} = PlaytestRuns.normalize(decoded)
    end

    test "totals are recomputed from the lines, never taken from the body" do
      body =
        PlaytestRuns.summary(@now)
        |> put_in(["month", "lines", "gm", "cost_micro_usd"], 5)
        |> put_in(["month", "runs_total_micro_usd"], 999_999)

      assert {:ok, %{"month" => %{"runs_total_micro_usd" => 5, "game_micro_usd" => 5}}} =
               PlaytestRuns.normalize(body)
    end

    test "rejects malformed bodies" do
      good = PlaytestRuns.summary(@now)

      assert PlaytestRuns.normalize("nope") == :error
      assert PlaytestRuns.normalize(%{}) == :error
      assert PlaytestRuns.normalize(%{"today" => %{}, "month" => %{}}) == :error
      assert PlaytestRuns.normalize(put_in(good, ["month", "lines", "gm", "calls"], -1)) == :error
      assert PlaytestRuns.normalize(put_in(good, ["today", "outside_runs"], nil)) == :error
      assert PlaytestRuns.normalize(Map.delete(good, "day_of_month")) == :error
      # The old shape (buckets, before this split) is not accepted.
      old = %{good | "month" => %{"buckets" => %{}}, "today" => %{"buckets" => %{}}}
      assert PlaytestRuns.normalize(old) == :error
    end
  end

  defp counts(calls, cost, capped \\ 0, errors \\ 0),
    do: %{"calls" => calls, "cost_micro_usd" => cost, "capped" => capped, "errors" => errors}

  defp run!(started_at) do
    {:ok, session} = GameSessions.create_session(%{name: "Persona run"})

    Repo.insert!(%PlaytestRun{
      game_session_id: session.id,
      persona: "careful",
      module: "tin_valley",
      turn_limit: 5,
      status: "finished",
      started_at: started_at
    })

    session
  end

  defp insert!(purpose, micro_usd, opts \\ []) do
    Repo.insert!(%AICall{
      purpose: purpose,
      call_type: Keyword.get(opts, :call_type, "llm"),
      model: Keyword.get(opts, :model, "grok-4.3"),
      status: Keyword.get(opts, :status, "ok"),
      latency_ms: 1,
      cost_micro_usd: micro_usd,
      game_session_id: opts[:session] && opts[:session].id,
      inserted_at: Keyword.get(opts, :at, @today)
    })
  end
end
