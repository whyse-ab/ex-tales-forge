defmodule TalesForge.Playtest.SeriesTest do
  use TalesForge.DataCase, async: false

  import ExUnit.CaptureLog
  import TalesForge.PlaytestHelpers

  alias TalesForge.GameSessions
  alias TalesForge.Playtest.Series
  alias TalesForge.Schemas.PlaytestRun

  doctest Series

  setup do
    Application.put_env(:ex_tales_forge, :playtest_runner_enabled, true)

    on_exit(fn ->
      Series.stop()

      for pid <- Task.Supervisor.children(TalesForge.Playtest.Supervisor),
          do: Task.Supervisor.terminate_child(TalesForge.Playtest.Supervisor, pid)

      Application.delete_env(:ex_tales_forge, :playtest_runner_enabled)
    end)

    :ok
  end

  defp seed(persona, notes, status, stop_reason) do
    {:ok, session} = GameSessions.create_session(%{name: "Seeded", adventure_id: "tin_valley"})

    %PlaytestRun{}
    |> PlaytestRun.changeset(%{
      game_session_id: session.id,
      persona: persona,
      module: "tin_valley",
      turn_limit: 10,
      status: status,
      stop_reason: stop_reason,
      started_at: DateTime.utc_now(:second),
      notes: notes
    })
    |> Repo.insert!()
  end

  defp await_series do
    wait_until(fn -> not Series.playing?() end, 1_000)
    wait_until(fn -> Task.Supervisor.children(TalesForge.Playtest.Supervisor) == [] end)
  end

  test "plans round by round, flipping the variant order, and skips done runs" do
    plan = Series.plan(~w(paul lotta), ~w(baseline default), 2)

    assert Enum.map(plan, &{&1.round, &1.persona, &1.variant}) == [
             {1, "paul", "baseline"},
             {1, "paul", "default"},
             {1, "lotta", "baseline"},
             {1, "lotta", "default"},
             {2, "paul", "default"},
             {2, "paul", "baseline"},
             {2, "lotta", "default"},
             {2, "lotta", "baseline"}
           ]

    done = %{{"paul", "baseline"} => 2, {"lotta", "default"} => 1}
    assert length(Series.plan(~w(paul lotta), ~w(baseline default), 2, done)) == 5
    assert Series.plan(~w(paul), ~w(default), 1, %{{"paul", "default"} => 3}) == []
  end

  test "counts finished and dead runs as done, by persona and variant" do
    seed("paul", Series.tag("ab_1", "baseline"), "finished", "turn_limit")
    seed("paul", Series.tag("ab_1", "baseline") <> " · smoke", "stopped", "dead")
    seed("paul", Series.tag("ab_1", "default"), "stopped", "spend_cap")
    seed("lotta", Series.tag("ab_1", "default"), "finished", "ended")
    seed("lotta", Series.tag("ab_1", "default"), "failed", "error")
    # Another series, and a name the LIKE wildcard `_` would otherwise match.
    seed("paul", Series.tag("ab_2", "default"), "finished", "turn_limit")
    seed("paul", Series.tag("abX1", "default"), "finished", "turn_limit")

    assert Series.done_counts("ab_1") == %{{"paul", "baseline"} => 2, {"lotta", "default"} => 1}

    assert %{other: %{"stopped/spend_cap" => 1, "failed/error" => 1}, playing?: false} =
             Series.progress("ab_1")
  end

  test "checks it is enabled and its options" do
    Application.put_env(:ex_tales_forge, :playtest_runner_enabled, false)

    assert Series.start("s", personas: ["paul"], variants: ["default"], runs: 1) ==
             {:error, :disabled}

    Application.put_env(:ex_tales_forge, :playtest_runner_enabled, true)

    assert Series.start("s", personas: [], variants: ["default"], runs: 1) ==
             {:error, :bad_options}

    assert Series.start("s", personas: ["paul"], variants: ["x y"], runs: 1) ==
             {:error, :bad_options}

    assert Series.start("a b", personas: ["paul"], variants: ["default"], runs: 1) ==
             {:error, :bad_options}

    assert Series.start("s", personas: ["paul"], variants: ["default"], runs: 0) ==
             {:error, :bad_options}

    assert Series.stop() == {:error, :not_running}
  end

  test "plays the plan one run at a time, tags each run, and resumes without repeats" do
    opts = [
      personas: ["paul"],
      variants: ["default"],
      runs: 2,
      turn_limit: 1,
      poll_ms: 20,
      busy_retry_ms: 20
    ]

    capture_log(fn ->
      assert {:ok, 2} = Series.start("smoke", Keyword.put(opts, :notes, "ci"))
      assert Series.start("smoke", opts) == {:error, :already_running}
      await_series()
    end)

    assert Series.done_counts("smoke") == %{{"paul", "default"} => 2}

    assert Repo.all(from r in PlaytestRun, select: {r.status, r.turns_played, r.notes}) ==
             List.duplicate({"finished", 1, "series=smoke variant=default · ci"}, 2)

    capture_log(fn ->
      assert {:ok, 0} = Series.start("smoke", opts)
      await_series()
    end)

    assert Repo.aggregate(PlaytestRun, :count) == 2
  end

  test "pauses at the first spend-cap stop and plays the rest when started again" do
    put_caps(session_micro_usd: 4_000)
    stub_llm(fn _kind, _user -> :default end)

    on_exit(fn ->
      System.put_env("LLM_PROVIDER", "mock")
      Application.delete_env(:ex_tales_forge, :ai_spend_caps)
    end)

    opts = [personas: ["lars"], variants: ["default"], runs: 2, turn_limit: 3, poll_ms: 20]

    log =
      capture_log(fn ->
        assert {:ok, 2} = Series.start("cap", opts)
        await_series()
      end)

    assert log =~ "playtest series paused series=cap: spend cap"
    assert %{done: done, other: %{"stopped/spend_cap" => 1}} = Series.progress("cap")
    assert done == %{}

    # The cap lifted (a new day): the series plays both runs, the stopped one again.
    Application.delete_env(:ex_tales_forge, :ai_spend_caps)

    capture_log(fn ->
      assert {:ok, 2} = Series.start("cap", Keyword.put(opts, :busy_retry_ms, 20))
      await_series()
    end)

    assert Series.done_counts("cap") == %{{"lars", "default"} => 2}
  end
end
