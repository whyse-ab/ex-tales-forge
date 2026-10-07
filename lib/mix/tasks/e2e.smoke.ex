defmodule Mix.Tasks.E2e.Smoke do
  @moduledoc """
  Live end-to-end smoke test against a running dev server and real LLM.

      mix phx.server   # terminal 1
      mix e2e.smoke    # terminal 2

  Writes `priv/playtest/reports/e2e-smoke.json`.
  """
  use Mix.Task

  import Ecto.Query

  alias TalesForge.GameSessions
  alias TalesForge.LLM
  alias TalesForge.NPC
  alias TalesForge.Repo
  alias TalesForge.Schemas.{Scene, Turn}

  @shortdoc "Run live E2E smoke test (requires mix phx.server + XAI_API_KEY)"

  @scenario [
    %{step: 1, action: "look around the tavern", npc_expect: :tavern_present},
    %{step: 2, action: "I ask Marta what the chalk marks mean", npc_expect: :marta_memory},
    %{step: 3, action: "I head outside to Crossroads Square", npc_expect: :square_present}
  ]

  @turn_timeout_ms 90_000
  @max_turn_latency_ms 3_000
  @poll_interval_ms 500
  @mock_marker "_Mock GM:"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    started_at = DateTime.utc_now()

    preflight = run_preflight()

    if preflight.status != :ok do
      write_report(%{
        status: "FAIL",
        started_at: DateTime.to_iso8601(started_at),
        preflight: preflight,
        steps: [],
        warnings: Map.get(preflight, :warnings, [])
      })

      System.halt(1)
    end

    Mix.shell().info("E2E smoke: starting tavern scenario (#{length(@scenario)} turns)")

    {:ok, session} = GameSessions.create_session(%{name: "E2E Smoke #{started_at}"})

    case wait_for_opening_scene(session.id) do
      {:ok, scene, latency_ms} ->
        Mix.shell().info(
          "  opening scene: #{scene.location_name} (#{latency_ms}ms, #{String.length(scene.narrative)} chars)"
        )

      {:error, reason} ->
        write_report(%{
          status: "FAIL",
          started_at: DateTime.to_iso8601(started_at),
          preflight: preflight,
          steps: [],
          warnings: ["opening scene: #{inspect(reason)}"]
        })

        System.halt(1)
    end

    {steps, warnings} =
      Enum.map_reduce(@scenario, [], fn step, warns ->
        run_step(session.id, step, warns)
      end)

    npc_checks = Enum.map(steps, &Map.take(&1, [:step, :npc_check, :npc_issues]))

    status = if Enum.all?(steps, &(&1.status == "PASS")), do: "PASS", else: "FAIL"

    report = %{
      status: status,
      started_at: DateTime.to_iso8601(started_at),
      finished_at: DateTime.to_iso8601(DateTime.utc_now()),
      session_id: session.id,
      llm_provider: TalesForge.Config.llm_provider(),
      llm_source: LLM.llm_source(LLM.provider()),
      preflight: preflight,
      steps: steps,
      npc_checks: npc_checks,
      warnings: warnings
    }

    write_report(report)
    print_summary(report)

    if status == "FAIL", do: System.halt(1)
  end

  defp run_preflight do
    dotenv_exists? = File.exists?(Path.expand(".env"))

    db_ok =
      case Repo.query("SELECT 1") do
        {:ok, _} -> true
        {:error, reason} -> {:error, Exception.message(reason)}
      end

    key = TalesForge.Config.xai_api_key()
    key_ok = key_present?(key)
    provider = TalesForge.Config.llm_provider()

    warnings =
      []
      |> maybe_warn(!dotenv_exists?, "missing .env file")
      |> maybe_warn(provider == "mock", "LLM_PROVIDER=mock — smoke test expects live API")
      |> maybe_warn(
        provider != "xai" and key_ok,
        "LLM provider is #{provider}, expected xai for smoke test"
      )

    server_ok = server_running?()

    checks = %{
      dotenv: File.exists?(Path.expand(".env")),
      database: db_ok == true,
      xai_api_key: key_ok,
      llm_provider: provider,
      server: server_ok
    }

    status =
      if checks.dotenv and checks.database and checks.xai_api_key and checks.server and
           provider != "mock",
         do: :ok,
         else: :error

    if status == :ok do
      Mix.shell().info("[ok] preflight passed (provider=#{provider})")
    else
      Mix.shell().error("[fail] preflight — #{inspect(checks)}")
      preflight_hints(checks)
    end

    %{status: status, checks: checks, warnings: warnings}
  end

  defp run_step(session_id, %{step: step_num, action: action} = step, warnings) do
    started = System.monotonic_time(:millisecond)
    Mix.shell().info("  step #{step_num}: #{action}")

    try do
      submit_step(session_id, step_num, action, Map.get(step, :npc_expect), started, warnings)
    rescue
      e ->
        latency = System.monotonic_time(:millisecond) - started

        step = %{
          step: step_num,
          action: action,
          status: "FAIL",
          latency_ms: latency,
          error: Exception.message(e)
        }

        Mix.shell().error("    FAIL — #{Exception.message(e)}")
        {step, ["#{action}: #{Exception.message(e)}" | warnings]}
    end
  end

  defp submit_step(session_id, step_num, action, npc_expect, started, warnings) do
    case submit_with_clarification(session_id, action) do
      {:ok, :processing} ->
        case wait_for_turn(session_id, step_num) do
          {:ok, turn, latency_ms} ->
            result = evaluate_turn(step_num, action, turn, latency_ms)
            {npc_issues, npc_check} = evaluate_npc_expect(session_id, npc_expect)
            result = merge_npc_result(result, npc_issues, npc_check)
            {result, warnings}

          {:error, reason} ->
            latency = System.monotonic_time(:millisecond) - started

            step = %{
              step: step_num,
              action: action,
              status: "FAIL",
              latency_ms: latency,
              error: inspect(reason)
            }

            Mix.shell().error("    FAIL — #{inspect(reason)}")
            {step, warnings}
        end

      {:error, reason} ->
        latency = System.monotonic_time(:millisecond) - started

        step = %{
          step: step_num,
          action: action,
          status: "FAIL",
          latency_ms: latency,
          error: inspect(reason)
        }

        Mix.shell().error("    FAIL — submit: #{inspect(reason)}")
        {step, warnings}
    end
  end

  defp submit_with_clarification(session_id, action, opts \\ []) do
    case GameSessions.submit_message(session_id, action, opts) do
      {:ok, %{status: :processing}} ->
        {:ok, :processing}

      {:ok, %{status: :clarification, clarification: clarification}} ->
        Mix.shell().info("    clarification needed — picking first option")

        option = List.first(clarification["options"])

        if option do
          submit_with_clarification(session_id, "",
            clarification_id: clarification["clarification_id"],
            option_id: option["id"]
          )
        else
          {:error, :no_clarification_options}
        end

      {:error, _} = err ->
        err
    end
  end

  defp wait_for_opening_scene(session_id) do
    deadline = System.monotonic_time(:millisecond) + @turn_timeout_ms
    wait_for_opening_scene(session_id, deadline, System.monotonic_time(:millisecond))
  end

  defp wait_for_opening_scene(session_id, deadline, started) do
    case fetch_opening_scene(session_id) do
      {:ok, scene} ->
        latency = System.monotonic_time(:millisecond) - started
        {:ok, scene, latency}

      :not_found ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(@poll_interval_ms)
          wait_for_opening_scene(session_id, deadline, started)
        end
    end
  end

  defp fetch_opening_scene(session_id) do
    scene =
      Scene
      |> where([s], s.game_session_id == ^session_id and s.location_id == "weary_pilgrim")
      |> Repo.one()

    if scene && String.trim(scene.narrative) != "" do
      {:ok, scene}
    else
      :not_found
    end
  end

  defp wait_for_turn(session_id, turn_number) do
    deadline = System.monotonic_time(:millisecond) + @turn_timeout_ms
    wait_for_turn(session_id, turn_number, deadline, System.monotonic_time(:millisecond))
  end

  defp wait_for_turn(session_id, turn_number, deadline, started) do
    case fetch_turn(session_id, turn_number) do
      {:ok, turn} ->
        latency = System.monotonic_time(:millisecond) - started
        {:ok, turn, latency}

      :not_found ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(@poll_interval_ms)
          wait_for_turn(session_id, turn_number, deadline, started)
        end
    end
  end

  defp fetch_turn(session_id, turn_number) do
    turn =
      Turn
      |> where([t], t.game_session_id == ^session_id and t.turn_number == ^turn_number)
      |> Repo.one()

    if turn, do: {:ok, turn}, else: :not_found
  end

  defp merge_npc_result(step, npc_issues, npc_check) do
    issues = step.issues ++ npc_issues
    status = if issues == [], do: "PASS", else: "FAIL"

    if npc_issues != [] do
      Mix.shell().error("    NPC — #{Enum.join(npc_issues, ", ")}")
    end

    step
    |> Map.put(:issues, issues)
    |> Map.put(:status, status)
    |> Map.put(:npc_issues, npc_issues)
    |> Map.put(:npc_check, npc_check)
  end

  defp evaluate_npc_expect(session_id, :tavern_present) do
    session = GameSessions.get_session!(session_id)
    present = Map.get(session.world_state, "present_npcs", [])

    issues =
      []
      |> then(fn i ->
        if "marta_kellen" in present, do: i, else: ["marta_kellen not present" | i]
      end)
      |> then(fn i ->
        if "worried_merchant" in present,
          do: ["worried_merchant should not be at tavern" | i],
          else: i
      end)

    {issues, %{present_npcs: present}}
  end

  defp evaluate_npc_expect(session_id, :marta_memory) do
    case NPC.get_instance(session_id, "marta_kellen") do
      nil ->
        {["marta_kellen instance missing"], %{}}

      inst ->
        memories = Map.get(inst.runtime_state, "memories", [])
        issues = if memories == [], do: ["marta has no memories after speak"], else: []
        {issues, %{marta_memories: length(memories)}}
    end
  end

  defp evaluate_npc_expect(session_id, :square_present) do
    session = GameSessions.get_session!(session_id)
    present = Map.get(session.world_state, "present_npcs", [])
    location = Map.get(session.world_state, "location_id")

    issues =
      []
      |> then(fn i ->
        if location == "crossroads_square", do: i, else: ["expected crossroads_square" | i]
      end)
      |> then(fn i ->
        if "worried_merchant" in present, do: i, else: ["worried_merchant not at square" | i]
      end)
      |> then(fn i ->
        if "marta_kellen" in present, do: ["marta_kellen should not be at square" | i], else: i
      end)

    {issues, %{present_npcs: present, location_id: location}}
  end

  defp evaluate_npc_expect(_session_id, _other), do: {[], %{}}

  defp evaluate_turn(step_num, action, turn, latency_ms) do
    narrative = turn.narrative || ""
    mock? = String.contains?(narrative, @mock_marker)
    empty? = String.trim(narrative) == ""
    llm_source = LLM.llm_source(LLM.provider())

    over_budget? = latency_ms > @max_turn_latency_ms

    issues =
      []
      |> then(fn i -> if empty?, do: ["empty narrative" | i], else: i end)
      |> then(fn i -> if mock?, do: ["mock GM narration" | i], else: i end)
      |> then(fn i -> if llm_source != "api", do: ["llm_source=#{llm_source}" | i], else: i end)
      |> then(fn i ->
        if over_budget?,
          do: ["turn latency budget exceeded (#{latency_ms}ms > #{@max_turn_latency_ms}ms)" | i],
          else: i
      end)

    status = if issues == [], do: "PASS", else: "FAIL"

    step = %{
      step: step_num,
      action: action,
      status: status,
      latency_ms: latency_ms,
      turn_number: turn.turn_number,
      narrative_preview: String.slice(narrative, 0, 200),
      mechanical: turn.mechanical_resolution,
      llm_source: llm_source,
      issues: issues
    }

    if status == "PASS" do
      Mix.shell().info("    PASS — #{latency_ms}ms, #{String.length(narrative)} chars")
    else
      Mix.shell().error("    FAIL — #{Enum.join(issues, ", ")}")
    end

    step
  end

  defp server_running? do
    case Req.get("http://localhost:4000", receive_timeout: 5_000, retry: false) do
      {:ok, %{status: status}} when status in 200..399 -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp maybe_warn(warnings, true, message), do: [message | warnings]
  defp maybe_warn(warnings, false, _message), do: warnings

  defp preflight_hints(%{server: false}) do
    Mix.shell().error(
      "[hint] Start Phoenix in another terminal first: mix phx.server\n" <>
        "       Then re-run: mix e2e.smoke"
    )
  end

  defp preflight_hints(_), do: :ok

  defp write_report(report) do
    path = Path.expand("priv/playtest/reports/e2e-smoke.json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(report, pretty: true))
    Mix.shell().info("Report written to #{path}")
  end

  defp print_summary(%{status: status, steps: steps, warnings: warnings}) do
    Mix.shell().info("")
    Mix.shell().info("E2E smoke: #{status}")

    for step <- steps do
      Mix.shell().info("  step #{step.step}: #{step.status} (#{step.latency_ms}ms)")
    end

    for warning <- warnings do
      Mix.shell().info("  warning: #{warning}")
    end
  end

  defp key_present?(value), do: String.trim(value) != ""
end
