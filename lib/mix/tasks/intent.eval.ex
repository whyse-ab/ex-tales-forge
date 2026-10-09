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
    * `--ask-below` — clarification threshold to include in the clarifying table
      (and the calibrated ask threshold of the decision-band table).
    * `--ask-below-raw` — the raw-confidence ask threshold for both tables
      (default: each clarifying row's own threshold, and 0.45 for the band
      table); `0` turns the raw check off, which reproduces the bands before
      the raw check.
    * `--limit` — only the first N items of the split.
    * `--concurrency` — read N items at once (default 1).
    * `--timeout-ms` — the Jev reader's receive timeout (default 4000).
    * `--retries` — retries on 429/5xx for the Jev reader (default 0).
    * `--fixture` / `--worlds` — override the fixture paths.
    * `--jev-model` — Jev model (default `jev-1.13.0`).
    * `--cache` — a directory for Jev replies, keyed by the SHA-256 of each exact
      request (`TalesForge.IntentEval.Readers.request_key/3`). Unchanged requests
      are read from it instead of the network, so tuning post-processing or the
      calibration map costs nothing; any change to a request calls Jev again.
    * `--dump` — also write one JSON line per item (gold and every reading) to
      this path, for offline analysis.
    * `--out` — also write the report to this path.
    * `--fit-calibration` — fit the Jev confidence map
      (`TalesForge.IntentEval.Calibration.fit_scored/2`) on this run's Jev
      readings and write it to this path (normally
      `priv/intent/calibration.json`), with `--calibration-version`. Tune split
      only; prints the raw, in-sample and 5-fold cross-validated ECE.
  """

  use Mix.Task

  alias TalesForge.IntentEval

  @switches [
    split: :string,
    readers: :string,
    ask_below: :float,
    ask_below_raw: :float,
    limit: :integer,
    concurrency: :integer,
    timeout_ms: :integer,
    retries: :integer,
    fixture: :string,
    worlds: :string,
    jev_model: :string,
    api_key: :string,
    cache: :string,
    dump: :string,
    out: :string,
    fit_calibration: :string,
    calibration_version: :string,
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

    if opts[:fit_calibration] && (split != "tune" or is_nil(opts[:calibration_version])) do
      Mix.raise("--fit-calibration needs the tune split and --calibration-version.")
    end

    start_app()

    {key, source} = api_key(opts)
    Mix.shell().info("Jev key: #{source}")

    run_opts = build_opts(opts, split, key)
    {report, results} = IntentEval.run(run_opts)

    maybe_banner(split)
    Mix.shell().info(report)
    maybe_write(opts[:out], report)
    maybe_dump(opts[:dump], results)
    maybe_fit(opts[:fit_calibration], opts[:calibration_version], results)
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
    |> put_opt(:ask_below_raw, opts[:ask_below_raw])
    |> put_opt(:limit, opts[:limit])
    |> put_opt(:concurrency, opts[:concurrency])
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
    |> put_opt(:cache_dir, opts[:cache])
    |> put_opt(:timeout_ms, opts[:timeout_ms])
    |> put_opt(:max_retries, opts[:retries])
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

  defp maybe_dump(nil, _results), do: :ok

  defp maybe_dump(path, %{scored: scored}) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(scored, "\n", &dump_line/1) <> "\n")
    Mix.shell().info("Wrote #{path}")
  end

  # One JSON line per item: its id, category, gold labels and every reader's
  # normalised reading (probabilities included), for offline analysis.
  defp dump_line(%{item: item, readings: readings}) do
    Jason.encode!(%{
      id: item["id"],
      category: item["category"],
      gold: item["gold"],
      readings:
        Map.new(readings, fn {reader, reading} -> {reader, Map.drop(reading, [:reader])} end)
    })
  end

  defp maybe_fit(nil, _version, _results), do: :ok

  defp maybe_fit(path, version, %{scored: scored}) do
    {map, stats} = IntentEval.Calibration.fit_scored(scored, version: version)
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode_to_iodata!(map, pretty: true) |> IO.iodata_to_binary() |> Kernel.<>("\n")
    )

    Mix.shell().info(
      "\nCalibration #{version} (n=#{stats.n}, #{length(map["points"])} knots) -> #{path}\n" <>
        "ECE raw #{fmt(stats.raw_ece)}, in-sample #{fmt(stats.in_sample_ece)}, " <>
        "5-fold CV #{fmt(stats.cv_ece)}"
    )
  end

  defp fmt(nil), do: "n/a"
  defp fmt(x), do: :erlang.float_to_binary(x / 1, decimals: 3)

  defp summarise_cost(%{metrics: metrics}) do
    total = metrics |> Map.values() |> Enum.map(& &1.cost) |> Enum.sum()
    spent = metrics |> Map.values() |> Enum.map(&Map.get(&1, :spent, &1.cost)) |> Enum.sum()
    Mix.shell().info("\nTotal measured cost: $#{:erlang.float_to_binary(total / 1, decimals: 5)}")

    Mix.shell().info(
      "Spent on this run (cache misses): $#{:erlang.float_to_binary(spent / 1, decimals: 5)}"
    )
  end
end
