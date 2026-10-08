defmodule Mix.Tasks.Intent.Eval do
  @shortdoc "Scores intent readers against the labelled fixture"

  @moduledoc """
  Runs the offline intent evaluation (`TalesForge.IntentEval`) and prints a
  Markdown report.

      mix intent.eval                       # tune split, all readers
      mix intent.eval --readers jev,heuristic
      mix intent.eval --split holdout --i-mean-it
      mix intent.eval --out tmp/intent.md

  The Jev reader needs a TypeSafe key. It uses the first one set of `--api-key`,
  `TYPESAFE_INTENT_PLAYTEST_API_KEY`, `TYPESAFE_INTENT_API_KEY` and
  `TYPESAFE_API_KEY` (see `api_key/2`). Set `TYPESAFE_INTENT_PLAYTEST_API_KEY` on
  dev machines so eval runs bill to the playtest key, not production. Without a
  key the Jev reader reports errors rather than numbers. The task prints which
  source the key came from; the key itself is never printed.

  The task starts the app for its config, Repo (Tier 1 calls are recorded in
  `ai_calls`) and HTTP clients, but with
  `config :ex_tales_forge, :npc_recovery_on_boot, false`, so the boot NPC sync
  (`TalesForge.NPCRecovery`) does not touch the active sessions in the local
  database.

  ## Options

    * `--split` — `tune` (default), `holdout` or `all`. The holdout is locked:
      pass `--i-mean-it` to run it, so it is not spent by accident.
    * `--readers` — comma list of `jev,heuristic,tier1` (default all three).
    * `--ask-below` — clarification threshold to include in the clarifying table.
    * `--limit` — only the first N items of the split.
    * `--fixture` / `--worlds` — override the fixture paths.
    * `--jev-model` — Jev model (default `jev-1.13.0`).
    * `--out` — also write the report to this path.
  """

  use Mix.Task

  alias TalesForge.IntentEval

  @switches [
    split: :string,
    readers: :string,
    ask_below: :float,
    limit: :integer,
    fixture: :string,
    worlds: :string,
    jev_model: :string,
    api_key: :string,
    out: :string,
    i_mean_it: :boolean
  ]

  # Key sources in order of precedence after `--api-key`. The playtest intent key
  # comes first so dev and eval runs bill to it rather than to production.
  @key_env_vars ~w(TYPESAFE_INTENT_PLAYTEST_API_KEY TYPESAFE_INTENT_API_KEY TYPESAFE_API_KEY)

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    split = Keyword.get(opts, :split, "tune")

    if split == "holdout" and not Keyword.get(opts, :i_mean_it, false) do
      Mix.raise(
        "Refusing to run the holdout split without --i-mean-it (it is meant to stay unseen)."
      )
    end

    start_app()

    {key, source} = api_key(opts)
    Mix.shell().info("Jev key: #{source}")

    run_opts = build_opts(opts, split, key)
    {report, results} = IntentEval.run(run_opts)

    maybe_banner(split)
    Mix.shell().info(report)
    maybe_write(opts[:out], report)
    summarise_cost(results)
  end

  # Loads runtime config, turns off the boot NPC sync, then starts the app.
  # `app.start` does not re-run `app.config`, so the flag holds.
  defp start_app do
    Mix.Task.run("app.config")
    Application.put_env(:ex_tales_forge, :npc_recovery_on_boot, false)
    Mix.Task.run("app.start")
  end

  @doc """
  The TypeSafe key for the Jev reader and a label for where it came from.

  Precedence: `opts[:api_key]` (`--api-key`), then the env vars
  `TYPESAFE_INTENT_PLAYTEST_API_KEY`, `TYPESAFE_INTENT_API_KEY` and
  `TYPESAFE_API_KEY`. Blank values are skipped. Returns `{nil, "none"}` when no
  key is set. The label is safe to print; the key is not.

  `getenv` defaults to `System.get_env/1`; tests pass their own.
  """
  @spec api_key(keyword(), (String.t() -> String.t() | nil)) :: {String.t() | nil, String.t()}
  def api_key(opts, getenv \\ &System.get_env/1) do
    candidates = [{"--api-key", opts[:api_key]} | Enum.map(@key_env_vars, &{&1, getenv.(&1)})]

    Enum.find_value(candidates, {nil, "none"}, fn {source, value} ->
      if is_binary(value) and String.trim(value) != "", do: {value, source}
    end)
  end

  defp build_opts(opts, split, key) do
    [
      split: split,
      readers: readers(opts),
      jev: jev_opts(opts, key)
    ]
    |> put_opt(:ask_below, opts[:ask_below])
    |> put_opt(:limit, opts[:limit])
    |> put_opt(:fixture, opts[:fixture])
    |> put_opt(:worlds, opts[:worlds])
  end

  defp readers(opts) do
    case opts[:readers] do
      nil ->
        [:jev, :heuristic, :tier1]

      list ->
        list
        |> String.split(",", trim: true)
        |> Enum.map(&(&1 |> String.trim() |> String.to_existing_atom()))
    end
  end

  defp jev_opts(opts, key) do
    []
    |> put_opt(:model, opts[:jev_model])
    |> put_opt(:api_key, key)
  end

  defp put_opt(kw, _key, nil), do: kw
  defp put_opt(kw, key, value), do: Keyword.put(kw, key, value)

  defp maybe_banner("holdout") do
    Mix.shell().info([
      :yellow,
      "\n*** HOLDOUT SPLIT — do not tune on these numbers ***\n",
      :reset
    ])
  end

  defp maybe_banner(_split), do: :ok

  defp maybe_write(nil, _report), do: :ok

  defp maybe_write(path, report) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, report)
    Mix.shell().info("\nWrote #{path}")
  end

  defp summarise_cost(%{metrics: metrics}) do
    total = metrics |> Map.values() |> Enum.map(& &1.cost) |> Enum.sum()
    Mix.shell().info("\nTotal measured cost: $#{:erlang.float_to_binary(total / 1, decimals: 5)}")
  end
end
