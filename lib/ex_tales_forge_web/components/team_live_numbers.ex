defmodule TalesForgeWeb.TeamLiveNumbers do
  @moduledoc """
  The presentation's numbers that come from this app's own database, each
  group live when there is data and otherwise the bundled `data.json`
  (labelled "as of <date>"). Live or fallback is decided per group, never per
  number, so the numbers in a group always belong together.

  | group | live source | window | fallback (`data.json`) |
  |---|---|---|---|
  | `costs/2` | `ai_calls.cost_micro_usd` per Stockholm day (as the costs page: no function rows) | last 7 days | `ai_spend.playtest_day_totals_usd` |
  | `intent_latency/2` | `ai_calls` purpose `"intent"`, status ok | last 7 days | `intent_shadow` |
  | `persona_scores/2` | Jev turn scores (`playtest_scores` kind `"turn_affect"`) of runs started here | since 2026-10-07 | the last `playtest_series` batch |

  The GitHub-sourced groups (tests from CI, the decision log) come from the
  live PR feed (`TalesForge.PrFeed.Extras`). Every group has `:source`
  (`:live` or `:fallback`), `:as_of` and `:window`; `label/1` says which.
  """

  import Ecto.Query

  alias TalesForge.Playtest.JevHeadline
  alias TalesForge.Repo
  alias TalesForge.Schemas.{AICall, PlaytestRun, PlaytestScore}
  alias TalesForge.TeamPage

  @zone "Europe/Stockholm"
  @inception ~D[2026-10-07]

  @typedoc "Which window a group's numbers cover."
  @type window :: :last_7_days | :since_inception | :snapshot

  @typedoc "One group of numbers."
  @type group :: %{
          required(:source) => :live | :fallback,
          required(:as_of) => String.t() | nil,
          required(:window) => window(),
          optional(atom()) => term()
        }

  @doc "The day the project started counting (the first playtest batches): 2026-10-07."
  @spec inception() :: Date.t()
  def inception, do: @inception

  @doc """
  Every group at `now`: `data` is the decoded `data.json`, `extras` the PR
  feed's GitHub extras (`TalesForge.PrFeed.Extras.current/0`).
  """
  @spec all(map(), map(), DateTime.t()) :: %{atom() => group()}
  def all(data, extras, now \\ DateTime.utc_now()) do
    %{
      tests: tests(extras, data),
      decisions: decisions(extras, data),
      costs: costs(data, now),
      intent_latency: intent_latency(data, now),
      persona_scores: persona_scores(data, now)
    }
  end

  @doc "The same groups, all from `data` (renders without a mount or database)."
  @spec fallback(map()) :: %{atom() => group()}
  def fallback(data) do
    %{
      tests: tests(%{}, data),
      decisions: decisions(%{}, data),
      costs: costs_fallback(data),
      intent_latency: latency_fallback(data),
      persona_scores: scores_fallback(data)
    }
  end

  # ── Tests (CI on main, via GitHub) ───────────────────────────────────────

  @doc """
  The test numbers: live from the latest successful CI run on main (the PR
  feed's extras), else `data.json`'s `pace.tests`.

      iex> extras = %{tests: %{tests: 1120, doctests: 170, failures: 0, coverage_pct: 87.62,
      ...>   sha: "f7f3abdc", at: "2026-10-10T02:57:00Z", run_id: 1}}
      iex> TalesForgeWeb.TeamLiveNumbers.tests(extras, %{}) |> Map.take([:source, :tests, :origin])
      %{source: :live, tests: 1120, origin: "live from CI on main (f7f3abd)"}
      iex> data = %{"pace" => %{"as_of" => "2026-10-09", "tests" => %{"tests" => 900, "doctests" => 150}}}
      iex> TalesForgeWeb.TeamLiveNumbers.tests(%{}, data) |> Map.take([:source, :tests, :as_of])
      %{source: :fallback, tests: 900, as_of: "2026-10-09"}
  """
  @spec tests(map(), map()) :: group()
  def tests(extras, data) do
    case extras do
      %{tests: %{tests: _} = t} ->
        %{
          source: :live,
          origin: "live from CI on main (#{String.slice(t.sha || "", 0, 7)})",
          as_of: t.at && String.slice(t.at, 0, 10),
          window: :snapshot,
          tests: t.tests,
          doctests: t.doctests,
          failures: t.failures,
          coverage_pct: t.coverage_pct
        }

      _none ->
        t = TeamPage.get(data, ["pace", "tests"]) || %{}

        %{
          source: :fallback,
          as_of: t["as_of"] || TeamPage.get(data, ["pace", "as_of"]),
          window: :snapshot,
          tests: t["tests"],
          doctests: t["doctests"],
          failures: t["failures"],
          coverage_pct: t["coverage_pct"]
        }
    end
  end

  # ── Decisions (decisions.md on GitHub) ───────────────────────────────────

  @doc """
  The decision log: live from tales-forge-docs `docs/decisions.md` on GitHub
  (the PR feed's extras), else `data.json`'s `decisions`. `:total` counts
  every entry; `:by_date` is per day.

      iex> extras = %{decisions: %{total: 90, by_date: [%{"date" => "2026-10-10", "count" => 3}],
      ...>   fetched_at: ~U[2026-10-10 03:00:00Z]}}
      iex> TalesForgeWeb.TeamLiveNumbers.decisions(extras, %{}) |> Map.take([:source, :total, :as_of])
      %{source: :live, total: 90, as_of: "2026-10-10"}
  """
  @spec decisions(map(), map()) :: group()
  def decisions(extras, data) do
    case extras do
      %{decisions: %{total: total, by_date: by_date} = d} ->
        %{
          source: :live,
          origin: "live from decisions.md on GitHub",
          as_of: Date.to_iso8601(local_date(d.fetched_at)),
          window: :snapshot,
          total: total,
          by_date: by_date
        }

      _none ->
        %{
          source: :fallback,
          as_of: TeamPage.get(data, ["decisions", "as_of"]),
          window: :snapshot,
          total: TeamPage.get(data, ["decisions", "total"]),
          by_date: TeamPage.get(data, ["decisions", "by_date"]) || []
        }
    end
  end

  # ── Costs: AI spend per day, last 7 days ─────────────────────────────────

  @doc """
  AI spend on this app per Stockholm day for the last 7 days (today
  included, so today is partial): `:days` (`%{"date", "usd"}`, every day, 0
  when nothing was spent) and `:total_usd`. Fallback when there were no
  priced calls in the window.
  """
  @spec costs(map(), DateTime.t()) :: group()
  def costs(data, now \\ DateTime.utc_now()) do
    days = last_days(now, 7)
    from = day_start(hd(days))

    rows =
      AICall
      |> where([c], c.inserted_at >= ^from and c.call_type != "function")
      |> where([c], not is_nil(c.cost_micro_usd))
      |> group_by(
        [c],
        fragment("(? AT TIME ZONE 'UTC' AT TIME ZONE ?)::date", c.inserted_at, @zone)
      )
      |> select(
        [c],
        {fragment("(? AT TIME ZONE 'UTC' AT TIME ZONE ?)::date", c.inserted_at, @zone),
         sum(c.cost_micro_usd)}
      )
      |> Repo.all()
      |> Map.new(fn {date, micro} -> {date, to_int(micro)} end)

    if rows == %{} do
      costs_fallback(data)
    else
      day_rows = Enum.map(days, &%{"date" => Date.to_iso8601(&1), "usd" => usd(rows[&1] || 0)})

      %{
        source: :live,
        as_of: Date.to_iso8601(local_date(now)),
        window: :last_7_days,
        days: day_rows,
        total_usd: usd(rows |> Map.values() |> Enum.sum())
      }
    end
  rescue
    _db_error -> costs_fallback(data)
  end

  @doc """
  The costs fallback: the last 7 days of `data.json`'s playtest day totals.

      iex> data = %{"ai_spend" => %{"as_of" => "2026-10-09",
      ...>   "playtest_day_totals_usd" => [%{"date" => "2026-10-08", "usd" => 3.1}]}}
      iex> TalesForgeWeb.TeamLiveNumbers.costs_fallback(data)
      %{source: :fallback, as_of: "2026-10-09", window: :last_7_days,
        days: [%{"date" => "2026-10-08", "usd" => 3.1}], total_usd: 3.1}
  """
  @spec costs_fallback(map()) :: group()
  def costs_fallback(data) do
    days =
      (TeamPage.get(data, ["ai_spend", "playtest_day_totals_usd"]) || [])
      |> Enum.filter(&is_map/1)
      |> Enum.take(-7)

    %{
      source: :fallback,
      as_of: TeamPage.get(data, ["ai_spend", "as_of"]),
      window: :last_7_days,
      days: days,
      total_usd: days |> Enum.map(&(&1["usd"] || 0)) |> Enum.sum() |> round_usd()
    }
  end

  # ── Jev intent latency, last 7 days ──────────────────────────────────────

  @doc """
  The Jev intent call's latency on this app over the last 7 days: `:reads`,
  `:p50_ms`, `:p95_ms`, `:max_ms` and `:timeout_ms`. Fallback (the shadow
  test's numbers) when there were no reads.
  """
  @spec intent_latency(map(), DateTime.t()) :: group()
  def intent_latency(data, now \\ DateTime.utc_now()) do
    from = DateTime.add(now, -7, :day)

    latencies =
      AICall
      |> where(
        [c],
        c.purpose == "intent" and c.status == "ok" and c.inserted_at >= ^from and
          not is_nil(c.latency_ms)
      )
      |> select([c], c.latency_ms)
      |> Repo.all()
      |> Enum.sort()

    case latencies do
      [] ->
        latency_fallback(data)

      sorted ->
        %{
          source: :live,
          as_of: Date.to_iso8601(local_date(now)),
          window: :last_7_days,
          reads: length(sorted),
          p50_ms: percentile(sorted, 50),
          p95_ms: percentile(sorted, 95),
          max_ms: List.last(sorted),
          timeout_ms: TeamPage.get(data, ["intent_shadow", "timeout_ms"])
        }
    end
  rescue
    _db_error -> latency_fallback(data)
  end

  @doc """
  The latency fallback: the shadow test's numbers in `data.json`.

      iex> data = %{"intent_shadow" => %{"as_of" => "2026-10-09", "reads" => 125, "p50_ms" => 255,
      ...>   "p95_ms" => 340, "max_ms" => 729, "timeout_ms" => 1500}}
      iex> TalesForgeWeb.TeamLiveNumbers.latency_fallback(data) |> Map.take([:source, :p50_ms, :window])
      %{source: :fallback, p50_ms: 255, window: :snapshot}
  """
  @spec latency_fallback(map()) :: group()
  def latency_fallback(data) do
    s = TeamPage.get(data, ["intent_shadow"]) || %{}

    %{
      source: :fallback,
      as_of: s["as_of"],
      window: :snapshot,
      reads: s["reads"],
      p50_ms: s["p50_ms"],
      p95_ms: s["p95_ms"],
      max_ms: s["max_ms"],
      timeout_ms: s["timeout_ms"]
    }
  end

  @doc """
  Nearest-rank percentile of a sorted list.

      iex> TalesForgeWeb.TeamLiveNumbers.percentile([100, 200, 300, 400], 50)
      200
      iex> TalesForgeWeb.TeamLiveNumbers.percentile([100, 200, 300, 400], 95)
      400
  """
  @spec percentile([number()], number()) :: number()
  def percentile(sorted, p) do
    rank = max(1, ceil(p / 100 * length(sorted)))
    Enum.at(sorted, rank - 1)
  end

  # ── Persona scores since inception ───────────────────────────────────────

  @doc """
  The confidence-weighted Jev score per persona (`TalesForge.Playtest.JevHeadline`)
  over every scored turn of the playtest runs started on this app since
  2026-10-07: `:runs` and `:by_persona` (`%{"paul" => %{score, unsure_pct,
  turns}}`). Fallback (the last batch in `data.json`) when there are none,
  as on production, where playtest runs don't live.
  """
  @spec persona_scores(map(), DateTime.t()) :: group()
  def persona_scores(data, now \\ DateTime.utc_now()) do
    since = day_start(@inception)

    rows =
      PlaytestScore
      |> join(:inner, [s], r in PlaytestRun, on: r.id == s.playtest_run_id)
      |> where([s, r], s.kind == "turn_affect" and r.started_at >= ^since)
      |> order_by([s], asc: s.turn_number, desc: s.inserted_at, desc: s.id)
      |> select([s, r], %{
        run: r.id,
        persona: r.persona,
        turn: s.turn_number,
        overall: s.overall,
        confidence: s.confidence
      })
      |> Repo.all()
      |> Enum.uniq_by(&{&1.run, &1.turn})
      |> Enum.reject(&is_nil(&1.overall))

    case rows do
      [] -> scores_fallback(data)
      rows -> live_scores(rows, now)
    end
  rescue
    _db_error -> scores_fallback(data)
  end

  defp live_scores(rows, now) do
    by_persona =
      rows
      |> Enum.group_by(& &1.persona)
      |> Map.new(fn {persona, turns} ->
        h =
          JevHeadline.summarize(
            Enum.map(turns, &%{overall: &1.overall, confidence: &1.confidence || 0.0})
          )

        {persona, %{score: h.score, unsure_pct: pct(h.unsure_share), turns: h.turns}}
      end)

    %{
      source: :live,
      as_of: Date.to_iso8601(local_date(now)),
      window: :since_inception,
      runs: rows |> Enum.map(& &1.run) |> Enum.uniq() |> length(),
      by_persona: by_persona
    }
  end

  @doc """
  The persona-scores fallback: the last batch in `data.json`'s playtest series.

      iex> data = %{"playtest_series" => %{"as_of" => "2026-10-09", "series" => [
      ...>   %{"completed_runs" => 25, "weighted" => %{"hawk" => 2.5}, "unsure_pct" => %{"hawk" => 40}}]}}
      iex> TalesForgeWeb.TeamLiveNumbers.scores_fallback(data)
      %{source: :fallback, as_of: "2026-10-09", window: :snapshot, runs: 25,
        by_persona: %{"hawk" => %{score: 2.5, unsure_pct: 40, turns: nil}}}
  """
  @spec scores_fallback(map()) :: group()
  def scores_fallback(data) do
    last = (TeamPage.get(data, ["playtest_series", "series"]) || []) |> List.last() || %{}

    %{
      source: :fallback,
      as_of: TeamPage.get(data, ["playtest_series", "as_of"]),
      window: :snapshot,
      runs: last["completed_runs"],
      by_persona:
        Map.new(last["weighted"] || %{}, fn {p, score} ->
          {p, %{score: score, unsure_pct: get_in(last, ["unsure_pct", p]), turns: nil}}
        end)
    }
  end

  # ── Labels ────────────────────────────────────────────────────────────────

  @doc """
  How a group is labelled: where it came from and the window.

      iex> TalesForgeWeb.TeamLiveNumbers.label(%{source: :live, window: :last_7_days, as_of: "2026-10-10"})
      "live · last 7 days"
      iex> TalesForgeWeb.TeamLiveNumbers.label(%{source: :live, window: :since_inception, as_of: "2026-10-10"})
      "live · since 2026-10-07"
      iex> TalesForgeWeb.TeamLiveNumbers.label(%{source: :fallback, window: :last_7_days, as_of: "2026-10-09"})
      "as of 9 Oct 2026 · last 7 days"
      iex> TalesForgeWeb.TeamLiveNumbers.label(%{source: :fallback, window: :snapshot, as_of: "2026-10-09"})
      "as of 9 Oct 2026"
  """
  @spec label(group()) :: String.t()
  def label(%{source: source, window: window} = group) do
    origin =
      case source do
        :live -> Map.get(group, :origin, "live")
        :fallback -> "as of " <> TeamPage.date_label(group.as_of)
      end

    case window_label(window) do
      nil -> origin
      w -> origin <> " · " <> w
    end
  end

  @doc """
  A window's label, or nil for a one-off snapshot.

      iex> TalesForgeWeb.TeamLiveNumbers.window_label(:since_inception)
      "since 2026-10-07"
  """
  @spec window_label(window()) :: String.t() | nil
  def window_label(:last_7_days), do: "last 7 days"
  def window_label(:since_inception), do: "since " <> Date.to_iso8601(@inception)
  def window_label(:snapshot), do: nil

  @doc """
  Keeps the day rows (`%{"date" => iso}`) on or after 2026-10-07, and says
  how many rows were earlier.

      iex> TalesForgeWeb.TeamLiveNumbers.since_inception([%{"date" => "2026-07-03"}, %{"date" => "2026-10-07"}])
      {[%{"date" => "2026-10-07"}], 1}
  """
  @spec since_inception([map()]) :: {[map()], non_neg_integer()}
  def since_inception(days) do
    {keep, earlier} =
      Enum.split_with(days, fn d ->
        is_binary(d["date"]) and d["date"] >= Date.to_iso8601(@inception)
      end)

    {keep, length(earlier)}
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp last_days(now, n) do
    today = local_date(now)
    for back <- (n - 1)..0//-1, do: Date.add(today, -back)
  end

  defp local_date(now),
    do: now |> DateTime.shift_zone!(@zone, TimeZoneInfo.TimeZoneDatabase) |> DateTime.to_date()

  defp day_start(date) do
    date
    |> DateTime.new!(~T[00:00:00], @zone, TimeZoneInfo.TimeZoneDatabase)
    |> DateTime.shift_zone!("Etc/UTC", TimeZoneInfo.TimeZoneDatabase)
  end

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_integer(n), do: n
  defp to_int(_other), do: 0

  defp usd(micro), do: round_usd(micro / 1_000_000)
  defp round_usd(x), do: Float.round(x * 1.0, 2)

  defp pct(nil), do: nil
  defp pct(share), do: round(share * 100)
end
