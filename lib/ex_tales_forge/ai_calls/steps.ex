defmodule TalesForge.AICalls.Steps do
  @moduledoc """
  Timings of the main Elixir steps of a turn, recorded in `ai_calls` as
  `call_type` `"function"` at zero cost (docs/call-types.md: an Elixir function
  is exact, free and should be instant; this shows whether it is).

  `collect/1` runs a turn and gathers every `time/2` made inside it in the
  calling process; `record/4` then writes one row per step with purpose
  `turn.<step>`. Outside `collect/1`, `time/2` just runs the function, so the
  same code works in tests and simulations that don't record.

  No telemetry dependency: a turn runs in one process (an Oban job), and the
  steps are few, so a process-local list is enough.
  """

  alias TalesForge.AICalls

  @key {__MODULE__, :steps}
  @model "elixir"

  @doc "Purposes of the turn steps, in pipeline order."
  def purposes,
    do:
      ~w(turn.intent turn.rules turn.world_facts turn.prices turn.npc_reactions turn.prompt turn.gm
         turn.world_writeback turn.persist)

  def model, do: @model

  @doc """
  Runs `fun`, returning `{result, steps}` with the steps timed inside it, in
  order. A raise or throw in `fun` comes back as `{{:crash, kind, reason,
  stacktrace}, steps}`, so the caller can still record the steps (the one that
  crashed has status `"error"`) and report the crash.
  """
  def collect(fun) when is_function(fun, 0) do
    previous = Process.put(@key, [])

    try do
      result =
        try do
          fun.()
        catch
          kind, reason -> {:crash, kind, reason, __STACKTRACE__}
        end

      {result, Enum.reverse(Process.get(@key, []))}
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @doc """
  Times `fun` as step `name` (an atom or string; stored as `turn.<name>`) and
  returns its result. A result of `{:error, _}` or `nil` marks the step as an
  error; so does a raise or throw, which is re-raised after the step is noted.
  """
  def time(name, fun) when is_function(fun, 0) do
    started_at = DateTime.utc_now()
    t0 = System.monotonic_time(:microsecond)

    try do
      fun.()
    catch
      kind, reason ->
        note(name, started_at, t0, "error")
        :erlang.raise(kind, reason, __STACKTRACE__)
    else
      result ->
        note(name, started_at, t0, status(result))
        result
    end
  end

  defp note(name, started_at, t0, status) do
    elapsed_us = System.monotonic_time(:microsecond) - t0

    case Process.get(@key) do
      steps when is_list(steps) ->
        step = %{
          purpose: "turn.#{name}",
          latency_ms: div(elapsed_us + 500, 1_000),
          started_at: started_at,
          status: status
        }

        Process.put(@key, [step | steps])

      _ ->
        :ok
    end
  end

  @doc "Writes the steps as function rows. Never raises (see `AICalls.record/1`)."
  def record(steps, session_id, turn_number, tags) do
    Enum.each(steps, fn step ->
      step
      |> Map.merge(tags)
      |> Map.merge(%{game_session_id: session_id, turn_number: turn_number})
      |> record_one()
    end)
  end

  @doc "Writes one function row for a step timed by the caller."
  def record_one(%{purpose: _, latency_ms: _} = step) do
    step
    |> Map.put_new(:status, "ok")
    |> Map.merge(%{
      call_type: "function",
      model: @model,
      cost_micro_usd: 0,
      cost_source: "free",
      usage: %{}
    })
    |> AICalls.record()
  end

  defp status({:error, _}), do: "error"
  defp status(nil), do: "error"
  defp status(_result), do: "ok"
end
