defmodule TalesForge.CodeHeat.Tracer do
  @moduledoc """
  Call-time tracing of the app's own modules with the BEAM's built-in tracer.

  The tracer uses one isolated trace session (`:trace.session_create/3`, OTP
  27). The session sets the `call` flag on all processes and a `call_time`
  pattern on each traced module. A `call_time` pattern sends no trace
  messages. The BEAM only counts the calls and the time in each function.
  Other tracers (for example the telemetry dashboard) keep their own sessions.

  The overhead is low and bounded:

  - Only the modules in the list get a pattern. Library and OTP code stays
    untraced.
  - The caller limits the list (`:max_modules` in `TalesForge.CodeHeat`).
  - `read/2` reads the counters. Then `stop/1` destroys the session and the
    BEAM removes all patterns and counters.

  Measured overhead (`mix code_heat.overhead`, OTP 27.3, 8 cores, 263 traced
  modules, 2026-10-10):

  - Each traced call takes 80 to 130 ns more.
  - A small function (0.33 µs) takes 0.43 to 0.47 µs. This is the worst case.
  - `TalesForgeWeb.AdminSections.breadcrumbs/2` (19 traced calls) takes
    1.8 µs untraced and 4.3 µs traced.
  - A request or a turn that makes 10,000 traced calls takes about 1.3 ms more.
    Database, LLM and Jev calls take most of the time of a turn.
  - Start of a session: 70 to 95 ms. Read of the counters: 12 to 13 ms. Stop:
    9 to 13 ms. The sampler does these once each hour.
  """

  @typedoc "A started trace session."
  @type session :: :trace.session()

  @typedoc "Counters of one function: `{module, function, arity, calls, time_us}`."
  @type row :: {module(), atom(), arity(), non_neg_integer(), non_neg_integer()}

  @doc """
  Starts a trace session and sets a `call_time` pattern on each module in
  `modules`. The tracer process is the caller. Returns `{:ok, session}`.
  """
  @spec start([module()]) :: {:ok, session()}
  def start(modules) when is_list(modules) do
    session = :trace.session_create(:code_heat, self(), [])
    _ = :trace.process(session, :all, true, [:call])

    Enum.each(modules, fn module ->
      _ = :trace.function(session, {module, :_, :_}, true, [:call_time])
    end)

    {:ok, session}
  end

  @doc """
  Reads the counters of each function in `modules`. Returns one row for
  each function with one or more calls. The counters of all processes
  are added together. The generated functions `module_info` and `__info__`
  are not in the result.
  """
  @spec read(session(), [module()]) :: [row()]
  def read(session, modules) do
    for module <- modules,
        {function, arity} <- functions(module),
        function not in [:module_info, :__info__],
        {calls, time_us} = counters(session, {module, function, arity}),
        calls > 0 do
      {module, function, arity, calls, time_us}
    end
  end

  @doc """
  Stops the session. The BEAM removes its patterns, flags and counters.
  Returns `:ok`, also for a session that is already stopped.
  """
  @spec stop(session()) :: :ok
  def stop(session) do
    _ = :trace.session_destroy(session)
    :ok
  end

  defp functions(module) do
    if function_exported?(module, :module_info, 1),
      do: module.module_info(:functions),
      else: []
  end

  defp counters(session, mfa) do
    case :trace.info(session, mfa, :call_time) do
      {:call_time, list} when is_list(list) ->
        Enum.reduce(list, {0, 0}, fn {_pid, count, s, us}, {calls, time} ->
          {calls + count, time + s * 1_000_000 + us}
        end)

      _ ->
        {0, 0}
    end
  end
end
