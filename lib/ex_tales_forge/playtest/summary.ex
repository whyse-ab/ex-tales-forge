defmodule TalesForge.Playtest.Summary do
  @moduledoc """
  The founder-readable summary at the top of the admin playtest page
  (`TalesForgeWeb.AdminLive.PlaytestLive.Index`).

  Two curated files in `priv/playtest/summary/`, edited in git like the other
  authored content:

  - `summary.md`: plain-language Markdown. The part before the
    `<!-- batches -->` line is the intro (what we test and how), the part after
    it the main findings, with links to run pages (`/admin/play/runs/<run id>`).
  - `batches.json`: one entry per batch of runs, oldest first: title, date,
    commit, what the game looked like, what changed since the batch before,
    notes, and the numbers from the written analysis (per persona: runs, mean
    session score, best and worst run, lead-by-turn-2 rate, brush-off rate,
    cost per run).

  A batch with a `series` name (the `series=NAME variant=V` notes tag written
  by `TalesForge.Playtest.Series`, optionally followed by ` arm=A` for one arm
  of a comparison) also gets live numbers from this database:
  done runs, mean score, best and worst run, cost per run and commit, per
  persona. They replace the curated ones whenever the series has runs here, so
  a new batch only needs a short entry in `batches.json` and its numbers fill in
  as the runs finish. Rates that need the transcripts read (lead by turn 2,
  brush-offs) stay curated. A batch whose runs are not in this database (the
  Elara runs, or any batch on production) shows the curated numbers.

  The live score of a run is its **first** Jev `session_affect` score, the
  scoring pass the analyses use; a later re-score does not move a batch.

  Run counts: `runs` in `batches.json` is the number of runs the batch's
  numbers are based on (the completed runs for a finished batch),
  `planned_runs` the number it set out to play (default: `runs`), and `status`
  says whether the batch is `"done"` (the default) or still `"running"`.
  """

  import Ecto.Query

  alias TalesForge.Playtest.Reports
  alias TalesForge.Repo
  alias TalesForge.Schemas.{PlaytestRun, PlaytestScore}

  @marker "<!-- batches -->"

  @personas ~w(paul lotta lars hawk ronny)

  # The series run on the playtest server; its run pages are linked from
  # servers that don't have the runs (`run_url/2`).
  @playtest_server "https://tales-forge-playtest.fly.dev"

  # A persona the series has not played yet: no live numbers, never the curated ones.
  @no_live_runs %{
    runs: 0,
    mean: nil,
    best: nil,
    best_score: nil,
    worst: nil,
    worst_score: nil,
    cost_per_run_usd: nil
  }

  @persona_keys ~w(runs mean best best_score worst worst_score hook_by_turn_2 brush_off cost_per_run_usd)a

  @typedoc "One persona's numbers in a batch. Every value may be nil (not measured)."
  @type persona_stats :: %{
          runs: non_neg_integer() | nil,
          mean: float() | nil,
          best: String.t() | nil,
          best_score: float() | nil,
          worst: String.t() | nil,
          worst_score: float() | nil,
          hook_by_turn_2: float() | nil,
          brush_off: float() | nil,
          cost_per_run_usd: float() | nil
        }

  @typedoc "Batch-wide rates and cost; every value may be nil."
  @type overall :: %{
          hook_by_turn_2: float() | nil,
          brush_off: float() | nil,
          cost_per_run_usd: float() | nil
        }

  @typedoc """
  One batch of runs. `runs` is the curated count of runs the numbers rest on, or
  the live count of done runs when `source` is `:live`; `planned_runs` is how many
  the batch set out to play; `status` is `:done` or `:running`. `arm` narrows a
  series to one arm of a comparison (`arm=A` after the variant in the run
  notes). `personas` keeps the persona order of the page.
  """
  @type batch :: %{
          id: String.t(),
          title: String.t(),
          date: String.t() | nil,
          commit: String.t() | nil,
          commit_note: String.t() | nil,
          series: String.t() | nil,
          variant: String.t() | nil,
          arm: String.t() | nil,
          status: :done | :running,
          runs: non_neg_integer() | nil,
          planned_runs: non_neg_integer() | nil,
          analysis: String.t() | nil,
          game: String.t() | nil,
          changes: String.t() | nil,
          notes: String.t() | nil,
          overall: overall(),
          personas: [{String.t(), persona_stats()}],
          source: :curated | :live
        }

  @typedoc "The loaded summary: intro and findings Markdown, and the batches."
  @type t :: %{intro: String.t(), findings: String.t(), batches: [batch()]}

  @doc """
  The directory holding `summary.md` and `batches.json`: `priv/playtest/summary`
  of this release, unless the `:playtest_summary_dir` app env points elsewhere
  (tests).
  """
  @spec dir() :: String.t()
  def dir do
    Application.get_env(:ex_tales_forge, :playtest_summary_dir) ||
      Application.app_dir(:ex_tales_forge, "priv/playtest/summary")
  end

  @doc """
  Reads the curated files from `dir` (default `dir/0`), without live numbers.
  `{:error, reason}` when a file is missing or `batches.json` is not a
  `%{"batches" => [...]}` object.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(dir \\ dir()) do
    with {:ok, markdown} <- File.read(Path.join(dir, "summary.md")),
         {:ok, json} <- File.read(Path.join(dir, "batches.json")),
         {:ok, %{"batches" => batches}} when is_list(batches) <- Jason.decode(json) do
      {intro, findings} = split(markdown)
      {:ok, %{intro: intro, findings: findings, batches: Enum.map(batches, &batch/1)}}
    else
      {:ok, _other} -> {:error, :invalid_batches}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `load/1` plus live numbers from this database for every batch with a series
  (`with_live/1`). This is what the playtest page shows.
  """
  @spec current(String.t()) :: {:ok, t()} | {:error, term()}
  def current(dir \\ dir()) do
    with {:ok, summary} <- load(dir) do
      {:ok, %{summary | batches: with_live(summary.batches)}}
    end
  end

  @doc """
  Splits the summary Markdown at the `<!-- batches -->` line into the intro
  and the findings.

      iex> TalesForge.Playtest.Summary.split("Intro\\n<!-- batches -->\\nFindings")
      {"Intro", "Findings"}

      iex> TalesForge.Playtest.Summary.split("Only an intro")
      {"Only an intro", ""}
  """
  @spec split(String.t()) :: {String.t(), String.t()}
  def split(markdown) when is_binary(markdown) do
    case String.split(markdown, @marker, parts: 2) do
      [intro, findings] -> {String.trim(intro), String.trim(findings)}
      [intro] -> {String.trim(intro), ""}
    end
  end

  @doc """
  Replaces the curated numbers of each series batch with live ones from this
  database, when the series has done runs here. Other batches are returned
  unchanged.
  """
  @spec with_live([batch()]) :: [batch()]
  def with_live(batches), do: Enum.map(batches, &merge_live/1)

  @doc """
  Live numbers for the done runs (finished, or stopped by the character's
  death) of series `name`, optionally only `variant` and, within it, only
  comparison `arm` (`arm` needs a `variant`): the run count, the most
  common commit, the first start, cost per run, and per persona the runs, mean
  first Jev session score, best and worst run, and cost per run.
  """
  @spec live_stats(String.t(), String.t() | nil, String.t() | nil) :: %{
          runs: non_neg_integer(),
          commit: String.t() | nil,
          started_at: DateTime.t() | nil,
          cost_per_run_usd: float() | nil,
          personas: %{optional(String.t()) => persona_stats()}
        }
  def live_stats(name, variant \\ nil, arm \\ nil) do
    done = series_runs(name, variant, arm)
    scores = first_session_scores(Enum.map(done, & &1.id))
    costs = Reports.session_costs(Enum.map(done, & &1.game_session_id))

    runs =
      Enum.map(done, fn run ->
        cost = Map.get(costs, run.game_session_id, 0) + (run.persona_cost_micro_usd || 0)
        Map.merge(run, %{score: Map.get(scores, run.id), cost_micro_usd: cost})
      end)

    %{
      runs: length(runs),
      commit: most_common(Enum.map(runs, & &1.git_sha)),
      started_at: runs |> Enum.map(& &1.started_at) |> Enum.min(DateTime, fn -> nil end),
      cost_per_run_usd: cost_per_run(runs),
      personas:
        runs |> Enum.group_by(& &1.persona) |> Map.new(fn {p, rs} -> {p, persona_live(rs)} end)
    }
  end

  @doc """
  The ids of the summary's best and worst runs that are in this database. The
  curated runs were played on the playtest server; on any other server
  (production, a laptop) `run_url/2` links them there instead.
  """
  @spec local_run_ids([batch()]) :: MapSet.t(String.t())
  def local_run_ids(batches) do
    ids =
      for batch <- batches,
          {_persona, stats} <- batch.personas,
          id <- [stats.best, stats.worst],
          is_binary(id),
          match?({:ok, _}, Ecto.UUID.cast(id)),
          uniq: true,
          do: id

    PlaytestRun
    |> where([r], r.id in ^ids)
    |> select([r], r.id)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Where a summary run link goes: the run page on this server when the run is
  here (`local_ids`, from `local_run_ids/1`), otherwise the run page on the
  playtest server, where the series run (by its old path, which every
  version of the playtest app understands; `TalesForge.AdminPaths.legacy/1`).

      iex> TalesForge.Playtest.Summary.run_url("abc", MapSet.new(["abc"]))
      "/admin/play/runs/abc"
      iex> TalesForge.Playtest.Summary.run_url("abc", MapSet.new())
      "https://tales-forge-playtest.fly.dev/admin/playtest/abc"
  """
  @spec run_url(String.t(), MapSet.t(String.t())) :: String.t()
  def run_url(id, local_ids) do
    if MapSet.member?(local_ids, id),
      do: "/admin/play/runs/" <> id,
      else: @playtest_server <> "/admin/playtest/" <> id
  end

  @doc ~S(Display name for a persona id: `"hawk"` → `"Hawk"`.)
  @spec persona_name(String.t()) :: String.t()
  def persona_name(id) when is_binary(id), do: String.capitalize(id)

  # --- curated file → batch ---------------------------------------------------

  defp batch(map) when is_map(map) do
    personas = Map.get(map, "personas") || %{}

    %{
      id: to_string(map["id"]),
      title: to_string(map["title"] || map["id"]),
      date: map["date"],
      commit: map["commit"],
      commit_note: map["commit_note"],
      series: map["series"],
      variant: map["variant"],
      arm: map["arm"],
      status: status(map["status"]),
      runs: map["runs"],
      planned_runs: map["planned_runs"] || map["runs"],
      analysis: map["analysis"],
      game: map["game"],
      changes: map["changes"],
      notes: map["notes"],
      overall: overall(map["overall"] || %{}),
      personas: persona_list(personas),
      source: :curated
    }
  end

  defp status("running"), do: :running
  defp status(_done), do: :done

  defp overall(map) do
    %{
      hook_by_turn_2: number(map["hook_by_turn_2"]),
      brush_off: number(map["brush_off"]),
      cost_per_run_usd: number(map["cost_per_run_usd"])
    }
  end

  # Known personas in page order, then any other ids alphabetically.
  defp persona_list(personas) do
    ids = Map.keys(personas)
    ordered = Enum.filter(@personas, &(&1 in ids)) ++ Enum.sort(ids -- @personas)
    Enum.map(ordered, &{&1, persona_stats(personas[&1] || %{})})
  end

  defp persona_stats(map) do
    Map.new(@persona_keys, fn key ->
      value = map[Atom.to_string(key)]
      {key, if(key in [:best, :worst], do: value, else: number(value))}
    end)
  end

  defp number(value) when is_number(value), do: value
  defp number(_value), do: nil

  # --- live numbers -------------------------------------------------------------

  defp merge_live(%{series: series} = batch) when is_binary(series) and series != "" do
    case live_stats(series, batch.variant, batch.arm) do
      %{runs: 0} -> batch
      live -> apply_live(batch, live)
    end
  end

  defp merge_live(batch), do: batch

  defp apply_live(batch, live) do
    curated = Map.new(batch.personas)
    ids = Map.keys(curated) ++ Map.keys(live.personas)
    ordered = Enum.filter(@personas, &(&1 in ids)) ++ Enum.sort(Enum.uniq(ids) -- @personas)

    personas =
      Enum.map(ordered, fn id ->
        base = Map.get(curated, id, persona_stats(%{}))
        {id, Map.merge(base, Map.get(live.personas, id, @no_live_runs))}
      end)

    %{
      batch
      | runs: live.runs,
        commit: live.commit || batch.commit,
        date: batch.date || stockholm_date(live.started_at),
        overall: %{batch.overall | cost_per_run_usd: live.cost_per_run_usd},
        personas: personas,
        source: :live
    }
  end

  defp persona_live(runs) do
    scored = Enum.filter(runs, &is_number(&1.score))
    best = Enum.max_by(scored, & &1.score, fn -> nil end)
    worst = Enum.min_by(scored, & &1.score, fn -> nil end)

    %{
      runs: length(runs),
      mean: mean(Enum.map(scored, & &1.score)),
      best: best && best.id,
      best_score: best && best.score,
      worst: worst && worst.id,
      worst_score: worst && worst.score,
      cost_per_run_usd: cost_per_run(runs)
    }
  end

  defp stockholm_date(nil), do: nil

  defp stockholm_date(%DateTime{} = at) do
    at
    |> DateTime.shift_zone!("Europe/Stockholm", TimeZoneInfo.TimeZoneDatabase)
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end

  defp mean([]), do: nil
  defp mean(values), do: Float.round(Enum.sum(values) / length(values), 2)

  defp cost_per_run([]), do: nil

  defp cost_per_run(runs),
    do: Enum.sum(Enum.map(runs, & &1.cost_micro_usd)) / length(runs) / 1_000_000

  defp most_common(values) do
    case values
         |> Enum.reject(&is_nil/1)
         |> Enum.frequencies()
         |> Enum.max_by(&elem(&1, 1), fn -> nil end) do
      nil -> nil
      {value, _count} -> value
    end
  end

  defp series_runs(name, variant, arm) do
    tag =
      if is_binary(variant) and is_binary(arm),
        do: "series=#{name} variant=#{variant} arm=#{arm}",
        else: "series=#{name} variant=#{variant}"

    PlaytestRun
    |> where_tagged(tag, is_binary(variant))
    |> where([r], r.status == "finished" or (r.status == "stopped" and r.stop_reason == "dead"))
    |> select(
      [r],
      map(r, [:id, :persona, :git_sha, :started_at, :game_session_id, :persona_cost_micro_usd])
    )
    |> Repo.all()
  end

  # A full tag (a variant, maybe an arm) must end at a space or the end of the
  # notes, so arm "on" doesn't take arm "online"; without a variant, the tag
  # "series=NAME variant=" is a prefix of every variant.
  defp where_tagged(query, tag, true = _whole) do
    pattern = escape_like(tag) <> " %"
    where(query, [r], r.notes == ^tag or like(r.notes, ^pattern))
  end

  defp where_tagged(query, tag, false) do
    pattern = escape_like(tag) <> "%"
    where(query, [r], like(r.notes, ^pattern))
  end

  defp escape_like(text), do: String.replace(text, ~w(\\ % _), &"\\#{&1}")

  defp first_session_scores([]), do: %{}

  defp first_session_scores(run_ids) do
    PlaytestScore
    |> where([s], s.playtest_run_id in ^run_ids and s.kind == "session_affect")
    |> where([s], not is_nil(s.overall))
    |> order_by([s], [s.playtest_run_id, asc: s.inserted_at, asc: s.id])
    |> distinct([s], s.playtest_run_id)
    |> select([s], {s.playtest_run_id, s.overall})
    |> Repo.all()
    |> Map.new()
  end
end
