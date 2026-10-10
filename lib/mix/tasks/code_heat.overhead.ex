defmodule Mix.Tasks.CodeHeat.Overhead do
  @shortdoc "Measures the overhead of the code heat map's call-time tracing"

  @moduledoc """
  Measures the overhead of `TalesForge.CodeHeat.Tracer`.

      mix code_heat.overhead [--runs 200000]

  The task runs two workloads without tracing and with tracing of all the
  app's modules (`TalesForge.CodeHeat.traced_modules/0`):

  - `small`: one call of a small app function (the worst case for each call).
  - `page`: `TalesForgeWeb.AdminSections.breadcrumbs/2`, which calls more
    app functions and does real work.

  Then it measures the time to start the session, read the counters and stop
  the session. It prints the results. It writes nothing.
  """
  use Mix.Task

  alias TalesForge.CodeHeat
  alias TalesForge.CodeHeat.Tracer

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {opts, _rest} = OptionParser.parse!(args, strict: [runs: :integer])
    runs = Keyword.get(opts, :runs, 200_000)
    Mix.Task.run("app.config")
    {:ok, _apps} = Application.ensure_all_started(:time_zone_info)

    modules = CodeHeat.traced_modules()

    workloads = [
      {"small", fn -> TalesForge.AppRole.playtest?("tales-forge-playtest") end},
      {"page", fn -> TalesForgeWeb.AdminSections.breadcrumbs("costs", nil, :local) end}
    ]

    Mix.shell().info("modules=#{length(modules)} runs=#{runs}")

    Enum.each(workloads, fn {name, fun} ->
      base = measure(fun, runs)
      {:ok, session} = Tracer.start(modules)
      traced = measure(fun, runs)
      :ok = Tracer.stop(session)
      extra = traced - base
      calls = traced_calls(fun, modules)

      Mix.shell().info(
        "#{name}: off=#{fmt(base)} µs/run on=#{fmt(traced)} µs/run " <>
          "extra=#{fmt(extra)} µs/run (#{fmt(extra / base * 100)} %), " <>
          "traced calls/run=#{fmt(calls)}, extra=#{fmt(extra / max(calls, 1) * 1000)} ns/call"
      )
    end)

    {start_us, {:ok, session}} = :timer.tc(fn -> Tracer.start(modules) end)

    Enum.each(1..10_000, fn _ -> TalesForgeWeb.AdminSections.breadcrumbs("costs", nil, :local) end)

    {read_us, rows} = :timer.tc(fn -> Tracer.read(session, modules) end)
    {stop_us, :ok} = :timer.tc(fn -> Tracer.stop(session) end)

    Mix.shell().info(
      "session: start=#{div(start_us, 1000)} ms read=#{div(read_us, 1000)} ms " <>
        "(#{length(rows)} functions) stop=#{div(stop_us, 1000)} ms"
    )
  end

  # The number of traced calls in one run of `fun`.
  defp traced_calls(fun, modules) do
    {:ok, session} = Tracer.start(modules)
    Enum.each(1..1000, fn _ -> fun.() end)
    rows = Tracer.read(session, modules)
    :ok = Tracer.stop(session)
    (rows |> Enum.map(&elem(&1, 3)) |> Enum.sum()) / 1000
  end

  # The best of 5 rounds, in µs for each run.
  defp measure(fun, runs) do
    Enum.map(1..5, fn _ ->
      {us, :ok} = :timer.tc(fn -> loop(fun, runs) end)
      us / runs
    end)
    |> Enum.min()
  end

  defp loop(_fun, 0), do: :ok

  defp loop(fun, n) do
    _ = fun.()
    loop(fun, n - 1)
  end

  defp fmt(n), do: :erlang.float_to_binary(n * 1.0, decimals: 3)
end
