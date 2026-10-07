defmodule TalesForge.Playtest.Runner do
  @moduledoc """
  Plays a new session as a persona bot in an adventure module, through the same
  paths a player uses, until the session ends, the character dies, a cap or
  timeout stops it, or the turn limit is reached. Each run is a `playtest_runs` row,
  scored by `TalesForge.Playtest.Scorer` when it finishes or stops.

  Off unless `PLAYTEST_RUNNER_ENABLED=true`; never set it in production. On playtest:

      bin/ex_tales_forge rpc 'TalesForge.Playtest.Runner.start("paul", "tin_valley") |> IO.inspect()'
      bin/ex_tales_forge rpc 'TalesForge.Playtest.Runner.status("RUN_ID") |> IO.inspect()'

  One run at a time per node. The bot sees only `TalesForge.Playtest.PlayerView`.
  """

  require Logger

  import Ecto.Query

  alias TalesForge.AICalls
  alias TalesForge.Game.SceneProcessor
  alias TalesForge.GameSessions
  alias TalesForge.LLM
  alias TalesForge.Playtest.{PersonaCharacters, Personas, PlayerView, Reports, RunMeta, Scorer}
  alias TalesForge.PubSub.GameSession, as: SessionPubSub
  alias TalesForge.Repo
  alias TalesForge.Schemas.{PlaytestRun, Turn}

  @supervisor TalesForge.Playtest.Supervisor
  @default_turn_limit 15
  @default_turn_timeout_ms 180_000
  # Oban attempts per turn or scene job; a failure before the last one is retried.
  @job_attempts 3
  @max_clarifications 2
  @poll_ms 5_000

  @stops %{
    ended: {"finished", "ended"},
    turn_limit: {"finished", "turn_limit"},
    spend_cap: {"stopped", "spend_cap"},
    persona_cap: {"stopped", "persona_cap"},
    dead: {"stopped", "dead"},
    timeout: {"stopped", "timeout"}
  }

  @doc """
  Starts a run and returns `{:ok, run_id}` at once.

  Options: `:turn_limit` (default #{@default_turn_limit}), `:turn_timeout_ms`
  (per turn or scene, default #{@default_turn_timeout_ms}), `:notes`, and
  `:variant` (`"default"` or `"baseline"`, see `TalesForge.Game.Variant`; nil
  means `GAME_VARIANT`), so both arms of a comparison run on one deploy, and
  `:character`: `:persona` (default) plays the character the persona created
  (`TalesForge.Playtest.PersonaCharacters`), `:default` the pack's default
  character (Elara). A persona without a pick plays the default character.
  """
  def start(persona_id, module, opts \\ []) do
    with :ok <- check_enabled(),
         {:ok, persona} <- Personas.fetch(persona_id),
         :ok <- check_module(module) do
      :global.trans({__MODULE__, self()}, fn -> start_run(persona, module, opts) end)
    end
  end

  def status(run_id) do
    with {:ok, id} <- Ecto.UUID.cast(run_id),
         %PlaytestRun{} = run <- Repo.get(PlaytestRun, id) do
      {:ok,
       run
       |> Map.take([
         :id,
         :game_session_id,
         :persona,
         :module,
         :build,
         :git_sha,
         :flags,
         :status,
         :stop_reason,
         :turns_played,
         :turn_limit,
         :started_at,
         :finished_at,
         :notes,
         :game_ms,
         :persona_calls,
         :persona_ms,
         :persona_input_tokens,
         :persona_output_tokens,
         :persona_cost_micro_usd
       ])
       |> Map.put(
         :game_cost_usd,
         AICalls.total_cost_for_session(run.game_session_id) / 1_000_000
       )
       |> Map.put(:metrics, Reports.metrics_summary(run.game_session_id))}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Polls `status/1` until the run is no longer running."
  def await(run_id, timeout_ms, poll_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(run_id, deadline, poll_ms)
  end

  defp do_await(run_id, deadline, poll_ms) do
    case status(run_id) do
      {:ok, %{status: "running"}} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(poll_ms)
          do_await(run_id, deadline, poll_ms)
        end

      other ->
        other
    end
  end

  def enabled?, do: Application.get_env(:ex_tales_forge, :playtest_runner_enabled, false)

  def modules do
    Application.app_dir(:ex_tales_forge, "priv/adventures") |> File.ls!() |> Enum.sort()
  end

  defp check_enabled, do: if(enabled?(), do: :ok, else: {:error, :disabled})

  defp check_module(module),
    do: if(module in modules(), do: :ok, else: {:error, :unknown_module})

  defp start_run(persona, module, opts) do
    if Task.Supervisor.children(@supervisor) == [] do
      fail_interrupted_runs()
      launch(persona, module, opts)
    else
      {:error, :already_running}
    end
  end

  defp launch(persona, module, opts) do
    with {:ok, character, description} <- persona_character(persona, module, opts),
         {:ok, session} <-
           %{
             name: "Playtest: #{persona.name} · #{module}",
             adventure_id: module,
             variant: opts[:variant],
             controller: "bot",
             controller_ref: persona.id
           }
           |> put_character(character)
           |> GameSessions.create_session(),
         {:ok, run} <- insert_run(session, persona, module, opts),
         play_opts = Keyword.put(opts, :character_description, description),
         {:ok, _pid} <-
           Task.Supervisor.start_child(@supervisor, fn -> play(run, persona, play_opts) end) do
      Logger.info("playtest run started run=#{run.id} persona=#{persona.id} module=#{module}")
      {:ok, run.id}
    end
  end

  defp persona_character(persona, module, opts) do
    with :persona <- Keyword.get(opts, :character, :persona),
         %{} = pick <- PersonaCharacters.pick(persona.id),
         {:ok, character} <- PersonaCharacters.build(persona.id, module) do
      {:ok, character, PersonaCharacters.describe(pick)}
    else
      {:error, reason} -> {:error, {:persona_character, reason}}
      _default -> {:ok, nil, nil}
    end
  end

  defp put_character(attrs, nil), do: attrs
  defp put_character(attrs, character), do: Map.put(attrs, :character, character)

  # Rows left "running" by a restart or crash: no task on this node plays them.
  defp fail_interrupted_runs do
    from(r in PlaytestRun, where: r.status == "running")
    |> Repo.update_all(set: [status: "failed", stop_reason: "error", finished_at: now()])
  end

  defp insert_run(session, persona, module, opts) do
    %PlaytestRun{}
    |> PlaytestRun.changeset(%{
      game_session_id: session.id,
      persona: persona.id,
      module: module,
      build: build(),
      git_sha: RunMeta.git_sha(),
      flags: RunMeta.flags(persona.id, session.world_state),
      turn_limit: Keyword.get(opts, :turn_limit, @default_turn_limit),
      status: "running",
      started_at: now(),
      notes: opts[:notes]
    })
    |> Repo.insert()
  end

  defp build do
    [Application.spec(:ex_tales_forge, :vsn), System.get_env("FLY_IMAGE_REF")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp play(run, persona, opts) do
    SessionPubSub.subscribe(run.game_session_id)

    state = %{
      run: run,
      system: Personas.system_prompt(persona, opts[:character_description]),
      timeout_ms: Keyword.get(opts, :turn_timeout_ms, @default_turn_timeout_ms),
      turns_played: 0
    }

    stop =
      try do
        loop(state)
      rescue
        e -> {:error, Exception.message(e)}
      catch
        kind, value -> {:error, {kind, value}}
      end

    finish(run, stop, opts)
  end

  defp loop(%{turns_played: played, run: %{turn_limit: limit}}) when played >= limit,
    do: :turn_limit

  defp loop(state) do
    with :ok <- ready_scene(state),
         {:ok, state} <- play_turn(state) do
      loop(state)
    end
  end

  defp ready_scene(state) do
    session = GameSessions.get_session!(state.run.game_session_id)

    cond do
      session.status == "dead" ->
        :dead

      session.status == "completed" ->
        :ended

      SceneProcessor.needs_scene?(session.world_state) ->
        timed(state, fn -> describe_scene(state, session) end)

      true ->
        :ok
    end
  end

  defp describe_scene(state, session) do
    with {:ok, _} <- GameSessions.ensure_scene(session), do: await_event(state, :scene)
  end

  defp play_turn(state) do
    with :ok <- gm_opened(state),
         {:ok, action} <- persona_move(state, nil) do
      submit(state, action, [], 0)
    end
  end

  # The GM always opens; the persona only ever responds. ready_scene/1 has
  # already waited for the opening scene job, so this is a guard: never let
  # the persona make the first move into a session without an opening.
  defp gm_opened(state) do
    if GameSessions.opening_scene(state.run.game_session_id),
      do: :ok,
      else: {:error, :no_opening_scene}
  end

  defp submit(state, text, opts, clarifications) do
    turns_before = turn_count(state)

    case timed(state, fn -> GameSessions.submit_message(state.run.game_session_id, text, opts) end) do
      {:ok, %{status: :processing}} ->
        state
        |> timed(fn -> await_event(state, {:turn, turns_before}) end)
        |> after_turn(state)

      {:ok, %{status: :clarification, clarification: clarification}} ->
        clarify(state, clarification, clarifications + 1)

      {:error, :needs_scene} ->
        with :ok <- ready_scene(state), do: submit(state, text, opts, clarifications)

      {:error, :dead} ->
        :dead

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp clarify(state, clarification, count) do
    with {:ok, action, option_id} <- persona_answer(state, clarification) do
      options = clarification["options"] || []
      base = [clarification_id: clarification["clarification_id"]]

      case Enum.find(options, &(&1["id"] == option_id)) || forced_option(options, count, action) do
        # The option label goes in as the player's text, as a typed answer would.
        %{"id" => id, "label" => label} -> submit(state, label, [{:option_id, id} | base], count)
        nil -> submit(state, action, base, count)
      end
    end
  end

  defp forced_option(options, count, action) do
    if count > @max_clarifications or String.trim(action) == "", do: List.first(options)
  end

  defp after_turn({:completed, payload}, state) do
    played = state.turns_played + 1
    update_run(state.run, Map.put(persona_totals(state.run), :turns_played, played))

    case Map.get(payload, :session_status) do
      "dead" -> :dead
      "completed" -> :ended
      _ -> {:ok, %{state | turns_played: played}}
    end
  end

  defp after_turn(stop, _state), do: stop

  defp persona_move(state, clarification) do
    with {:ok, action, _option_id} <- persona_answer(state, clarification), do: {:ok, action}
  end

  defp persona_answer(state, clarification) do
    user =
      PlayerView.render(
        state.run.game_session_id,
        clarification,
        state.turns_played + 1,
        state.run.turn_limit
      )

    case LLM.complete_persona(state.system, user,
           session_id: state.run.game_session_id,
           turn_number: state.turns_played + 1
         ) do
      {:ok, %{"action" => action} = move} when is_binary(action) ->
        {:ok, action, move["option_id"]}

      {:ok, move} ->
        {:error, {:invalid_persona_move, move}}

      {:error, {:spend_cap, :persona_run}} ->
        :persona_cap

      {:error, {:spend_cap, _kind}} ->
        :spend_cap

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Waits for the job's PubSub event. Every @poll_ms it also checks the database,
  # in case the job ran on a node whose broadcasts this one does not get.
  #
  # A turn_completed counts only if it is for a turn after `turns_before`. When
  # the database poll settles a turn first, that turn's own broadcast arrives
  # later and sits in the mailbox; taken as the next turn's completion, it made
  # the persona move while the next turn was still running, so the same turn
  # was narrated twice and one copy failed on the unique turn number.
  @doc false
  def await_event(state, kind) do
    deadline = System.monotonic_time(:millisecond) + state.timeout_ms
    await_event(state, kind, deadline, 0)
  end

  defp await_event(state, kind, deadline, failures) do
    remaining = deadline - System.monotonic_time(:millisecond)

    receive do
      {:scene_completed, _payload} when kind == :scene ->
        :ok

      {:turn_completed, payload} when is_tuple(kind) ->
        if fresh_turn?(state, kind, payload),
          do: {:completed, payload},
          else: await_event(state, kind, deadline, failures)

      {:scene_failed, reason} when kind == :scene ->
        failed(state, kind, deadline, failures, reason)

      {:turn_failed, reason} when is_tuple(kind) ->
        failed(state, kind, deadline, failures, reason)

      _other ->
        await_event(state, kind, deadline, failures)
    after
      max(min(remaining, @poll_ms), 0) ->
        cond do
          result = settled(state, kind) -> result
          remaining <= @poll_ms -> :timeout
          true -> await_event(state, kind, deadline, failures)
        end
    end
  end

  defp fresh_turn?(_state, {:turn, turns_before}, %{turn_count: n}) when is_integer(n),
    do: n > turns_before

  defp fresh_turn?(state, {:turn, turns_before}, _payload), do: turn_count(state) > turns_before

  defp failed(_state, _kind, _deadline, _failures, {:spend_cap, _cap}), do: :spend_cap

  defp failed(_state, _kind, _deadline, failures, reason) when failures + 1 >= @job_attempts,
    do: {:error, reason}

  defp failed(state, kind, deadline, failures, _reason),
    do: await_event(state, kind, deadline, failures + 1)

  defp settled(state, :scene) do
    session = GameSessions.get_session!(state.run.game_session_id)
    if not SceneProcessor.needs_scene?(session.world_state), do: :ok
  end

  defp settled(state, {:turn, turns_before}) do
    if turn_count(state) > turns_before do
      session = GameSessions.get_session!(state.run.game_session_id)
      {:completed, %{session_status: session.status}}
    end
  end

  defp turn_count(state) do
    Repo.aggregate(
      from(t in Turn, where: t.game_session_id == ^state.run.game_session_id),
      :count
    )
  end

  defp finish(run, stop, opts) do
    {status, stop_reason, error} =
      case stop do
        {:error, reason} ->
          {"failed", "error", reason}

        stop ->
          @stops |> Map.fetch!(stop) |> then(fn {status, reason} -> {status, reason, nil} end)
      end

    if error, do: Logger.error("playtest run failed run=#{run.id} reason=#{inspect(error)}")

    update_run(
      run,
      Map.merge(persona_totals(run), %{
        status: status,
        stop_reason: stop_reason,
        finished_at: now(),
        notes: notes(run.notes, error)
      })
    )

    Logger.info("playtest run done run=#{run.id} status=#{status} stop_reason=#{stop_reason}")
    if status != "failed" and Keyword.get(opts, :auto_score, true), do: auto_score(run)
  end

  # A scoring failure is logged and leaves the run as it is; it can be re-scored.
  defp auto_score(run) do
    Scorer.score(run.id)
  rescue
    e -> Logger.warning("playtest scoring crashed run=#{run.id} #{Exception.message(e)}")
  end

  defp notes(notes, nil), do: notes

  defp notes(notes, error) do
    [notes, "error: " <> String.slice(inspect(error), 0, 500)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # Game time only: the persona's think time is measured apart, from its ai_calls.
  defp timed(state, fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    ms = System.monotonic_time(:millisecond) - started

    from(r in PlaytestRun, where: r.id == ^state.run.id)
    |> Repo.update_all(inc: [game_ms: ms])

    result
  end

  defp persona_totals(run) do
    totals = AICalls.persona_totals(run.game_session_id)

    %{
      persona_calls: totals.calls,
      persona_ms: totals.latency_ms,
      persona_input_tokens: totals.input_tokens,
      persona_output_tokens: totals.output_tokens,
      persona_cost_micro_usd: totals.cost_micro_usd
    }
  end

  defp update_run(run, attrs) do
    PlaytestRun
    |> Repo.get!(run.id)
    |> PlaytestRun.changeset(attrs)
    |> Repo.update!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
