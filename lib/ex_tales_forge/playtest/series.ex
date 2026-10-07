defmodule TalesForge.Playtest.Series do
  @moduledoc """
  Plays a planned batch of playtest runs, one after another, so an A/B comparison
  (or a baseline) runs unattended on one deploy.

  The plan goes round by round: every round plays each persona once in every
  variant, and the variant order flips each round, so both arms are spread evenly
  over the same hours (same model, same load, same day).

  Each run is tagged in its notes with `series=NAME variant=VARIANT`. Starting a
  series again with the same name skips the runs it already has, so a batch
  stopped by the day spend cap simply continues the next day. Runs that finished,
  hit the turn limit or ended with the character's death count as done;
  spend-cap stops, timeouts and failures are played again.

  On playtest (`PLAYTEST_RUNNER_ENABLED=true`):

      bin/ex_tales_forge rpc 'TalesForge.Playtest.Series.start("jev-ab-1",
        personas: ~w(paul lotta lars hawk ronny), variants: ~w(baseline default),
        runs: 13, turn_limit: 10) |> IO.inspect()'
      bin/ex_tales_forge rpc 'TalesForge.Playtest.Series.progress("jev-ab-1") |> IO.inspect()'
      bin/ex_tales_forge rpc 'TalesForge.Playtest.Series.stop() |> IO.inspect()'

  The `variant` option is handed to `TalesForge.Playtest.Runner.start/3`; the game
  only acts on it once behaviour variants exist (a build without them plays every
  run the same way).
  """

  require Logger

  import Ecto.Query

  alias TalesForge.Playtest.Runner
  alias TalesForge.Repo
  alias TalesForge.Schemas.PlaytestRun

  @supervisor TalesForge.Playtest.SeriesSupervisor
  @default_module "tin_valley"
  @default_turn_limit 10
  @default_turn_timeout_ms 180_000
  @max_failures_in_a_row 3
  @busy_retry_ms 30_000

  @typedoc "One planned run."
  @type item :: %{persona: String.t(), variant: String.t(), round: pos_integer()}

  @typedoc "Done runs per `{persona, variant}`."
  @type counts :: %{optional({String.t(), String.t()}) => non_neg_integer()}

  @doc """
  The runs still to play, in order: round `r` holds every persona × variant pair
  that has fewer than `r` done runs. The variant order flips each round.

      iex> TalesForge.Playtest.Series.plan(~w(paul lotta), ~w(a b), 2, %{{"paul", "a"} => 1})
      [
        %{persona: "paul", variant: "b", round: 1},
        %{persona: "lotta", variant: "a", round: 1},
        %{persona: "lotta", variant: "b", round: 1},
        %{persona: "paul", variant: "b", round: 2},
        %{persona: "paul", variant: "a", round: 2},
        %{persona: "lotta", variant: "b", round: 2},
        %{persona: "lotta", variant: "a", round: 2}
      ]
  """
  @spec plan([String.t()], [String.t()], pos_integer(), counts()) :: [item()]
  def plan(personas, variants, runs, done \\ %{}) do
    for round <- 1..runs//1,
        persona <- personas,
        variant <- if(rem(round, 2) == 1, do: variants, else: Enum.reverse(variants)),
        Map.get(done, {persona, variant}, 0) < round,
        do: %{persona: persona, variant: variant, round: round}
  end

  @doc "The notes tag that marks a run as part of series `name` in `variant`."
  @spec tag(String.t(), String.t()) :: String.t()
  def tag(name, variant), do: "series=#{name} variant=#{variant}"

  @doc """
  Done runs of series `name`, per `{persona, variant}`: finished runs and runs
  stopped by the character's death.
  """
  @spec done_counts(String.t()) :: counts()
  def done_counts(name) do
    name
    |> series_runs()
    |> Enum.filter(&done?/1)
    |> Enum.frequencies_by(&{&1.persona, variant_of(&1.notes, name)})
  end

  @doc """
  Progress of series `name`: done runs per `{persona, variant}`, the other
  outcomes by status and stop reason, and whether a series is playing now.
  """
  @spec progress(String.t()) :: %{
          done: counts(),
          other: %{optional(String.t()) => non_neg_integer()},
          playing?: boolean()
        }
  def progress(name) do
    runs = series_runs(name)

    %{
      done: done_counts(name),
      other:
        runs
        |> Enum.reject(&done?/1)
        |> Enum.frequencies_by(&"#{&1.status}/#{&1.stop_reason}"),
      playing?: playing?()
    }
  end

  @doc """
  Starts series `name` in the background and returns `{:ok, planned}` with the
  number of runs still to play.

  Options: `:personas` and `:variants` (lists, required), `:runs` per persona and
  variant (required), `:module` (default `#{@default_module}`), `:turn_limit`
  (default #{@default_turn_limit}), `:turn_timeout_ms` (default
  #{@default_turn_timeout_ms}) and `:notes`, added after the series tag. Tests may
  shorten `:poll_ms` and `:busy_retry_ms`.

  The series stops at the first spend-cap stop (start it again once the cap
  resets), after #{@max_failures_in_a_row} failed or timed-out runs in a row, or
  on `stop/0`. One series at a time.
  """
  @spec start(String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :disabled | :already_running | :bad_options}
  def start(name, opts) do
    with :ok <- check_enabled(),
         {:ok, plan_opts} <- validate(name, opts) do
      :global.trans({__MODULE__, self()}, fn -> launch(name, plan_opts, opts) end)
    end
  end

  @doc "Stops the series. A run in progress plays to its end; nothing new starts."
  @spec stop() :: :ok | {:error, :not_running}
  def stop do
    case Task.Supervisor.children(@supervisor) do
      [] ->
        {:error, :not_running}

      pids ->
        Enum.each(pids, &Task.Supervisor.terminate_child(@supervisor, &1))
        :ok
    end
  end

  @doc "True while a series is playing on this node."
  @spec playing?() :: boolean()
  def playing?, do: Task.Supervisor.children(@supervisor) != []

  defp check_enabled, do: if(Runner.enabled?(), do: :ok, else: {:error, :disabled})

  defp validate(name, opts) do
    personas = Keyword.get(opts, :personas)
    variants = Keyword.get(opts, :variants)
    runs = Keyword.get(opts, :runs)

    if name =~ ~r/^[\w.-]+$/ and string_list?(personas) and string_list?(variants) and
         is_integer(runs) and runs > 0 do
      {:ok, {personas, variants, runs}}
    else
      {:error, :bad_options}
    end
  end

  defp string_list?([_ | _] = list), do: Enum.all?(list, &(is_binary(&1) and &1 =~ ~r/^\w+$/))
  defp string_list?(_), do: false

  defp launch(name, {personas, variants, runs}, opts) do
    if playing?() do
      {:error, :already_running}
    else
      items = plan(personas, variants, runs, done_counts(name))

      {:ok, _pid} =
        Task.Supervisor.start_child(@supervisor, fn -> play(name, items, opts, 0) end)

      Logger.info("playtest series started series=#{name} planned=#{length(items)}")
      {:ok, length(items)}
    end
  end

  defp play(name, [], _opts, _failures),
    do: Logger.info("playtest series done series=#{name}")

  defp play(name, _items, _opts, @max_failures_in_a_row),
    do: Logger.warning("playtest series stopped series=#{name}: failures in a row")

  defp play(name, [item | rest] = items, opts, failures) do
    case run_one(name, item, opts) do
      :busy ->
        Process.sleep(Keyword.get(opts, :busy_retry_ms, @busy_retry_ms))
        play(name, items, opts, failures)

      :done ->
        play(name, rest, opts, 0)

      :spend_cap ->
        Logger.warning("playtest series paused series=#{name}: spend cap, start it again later")

      {:failed, why} ->
        Logger.warning("playtest series run failed series=#{name} reason=#{inspect(why)}")
        play(name, rest, opts, failures + 1)
    end
  end

  defp run_one(name, item, opts) do
    turn_limit = Keyword.get(opts, :turn_limit, @default_turn_limit)
    turn_timeout = Keyword.get(opts, :turn_timeout_ms, @default_turn_timeout_ms)

    run_opts = [
      turn_limit: turn_limit,
      turn_timeout_ms: turn_timeout,
      variant: item.variant,
      notes: [tag(name, item.variant), opts[:notes]] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
    ]

    case Runner.start(item.persona, Keyword.get(opts, :module, @default_module), run_opts) do
      {:ok, run_id} ->
        run_id
        |> Runner.await((turn_limit + 2) * turn_timeout, Keyword.get(opts, :poll_ms, 5_000))
        |> outcome()

      {:error, :already_running} ->
        :busy

      {:error, why} ->
        {:failed, why}
    end
  end

  defp outcome({:ok, %{stop_reason: "spend_cap"}}), do: :spend_cap
  defp outcome({:ok, run}), do: if(done?(run), do: :done, else: {:failed, run.stop_reason})
  defp outcome({:error, why}), do: {:failed, why}

  defp done?(%{status: "finished"}), do: true
  defp done?(%{status: "stopped", stop_reason: "dead"}), do: true
  defp done?(_run), do: false

  defp series_runs(name) do
    prefix = String.replace("series=#{name} variant=", ~w(\\ % _), &"\\#{&1}")

    from(r in PlaytestRun,
      where: like(r.notes, ^"#{prefix}%"),
      select: map(r, [:persona, :notes, :status, :stop_reason])
    )
    |> Repo.all()
  end

  defp variant_of(notes, name) do
    notes
    |> String.replace_prefix("series=#{name} variant=", "")
    |> String.split(" ", parts: 2)
    |> hd()
  end
end
