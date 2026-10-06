defmodule Mix.Tasks.Playtest.Run do
  @moduledoc """
  Runs a persona bot locally and waits for it to finish. Needs
  `PLAYTEST_RUNNER_ENABLED=true` (plus `LLM_PROVIDER` and a key for a live run).

      mix playtest.run paul tin_valley
      mix playtest.run ronny crossroads_ledger --turns 5 --notes "red team"

  On a release, call `TalesForge.Playtest.Runner` over rpc instead.
  """
  use Mix.Task

  alias TalesForge.Playtest.Runner

  @shortdoc "Play a session as a persona bot"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: [turns: :integer, turn_timeout: :integer, notes: :string])

    [persona, module] =
      case positional do
        [_, _] = both -> both
        _ -> Mix.raise("Usage: mix playtest.run PERSONA MODULE [--turns N] [--notes TEXT]")
      end

    Mix.Task.run("app.start")

    runner_opts =
      [
        turn_limit: opts[:turns],
        turn_timeout_ms: opts[:turn_timeout] && opts[:turn_timeout] * 1_000,
        notes: opts[:notes]
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case Runner.start(persona, module, runner_opts) do
      {:ok, run_id} ->
        Mix.shell().info("Run #{run_id} started")
        Mix.shell().info(inspect(Runner.await(run_id, :timer.hours(2)), pretty: true))

      {:error, reason} ->
        Mix.raise("Could not start run: #{inspect(reason)}")
    end
  end
end
