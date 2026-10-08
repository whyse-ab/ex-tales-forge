defmodule Mix.Tasks.Intent.Eval do
  @shortdoc "Scores intent readers against the labelled fixture"

  @moduledoc """
  Runs the offline intent evaluation (`TalesForge.IntentEval`) and prints a
  Markdown report.

      mix intent.eval                       # tune split, all readers
      mix intent.eval --readers jev,heuristic
      mix intent.eval --split holdout --i-mean-it
      mix intent.eval --out tmp/intent.md

  The Jev reader needs a TypeSafe key: `--api-key`, or `TYPESAFE_INTENT_API_KEY`
  / `TYPESAFE_API_KEY` in the environment. Without one the Jev reader reports
  errors rather than numbers. The key is never printed.

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

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    split = Keyword.get(opts, :split, "tune")

    if split == "holdout" and not Keyword.get(opts, :i_mean_it, false) do
      Mix.raise(
        "Refusing to run the holdout split without --i-mean-it (it is meant to stay unseen)."
      )
    end

    Mix.Task.run("app.start")

    run_opts = build_opts(opts, split)
    {report, results} = IntentEval.run(run_opts)

    maybe_banner(split)
    Mix.shell().info(report)
    maybe_write(opts[:out], report)
    summarise_cost(results)
  end

  defp build_opts(opts, split) do
    [
      split: split,
      readers: readers(opts),
      jev: jev_opts(opts)
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

  defp jev_opts(opts) do
    key =
      opts[:api_key] || System.get_env("TYPESAFE_INTENT_API_KEY") ||
        System.get_env("TYPESAFE_API_KEY")

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
