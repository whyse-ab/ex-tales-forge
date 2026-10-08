defmodule TalesForge.AICalls.Metrics do
  @moduledoc """
  Derived metrics over `ai_calls`, for `/admin/costs` and playtest run reports.

  - **Breakdown:** count, total and average cost, p50/p90 latency per
    `call_type` and `purpose`, in sections: `"game"`, then the playtest bots
    `"persona"` and `"scorer"` (`TalesForge.AICalls.bucket/1`). Bot cost is never
    added to game cost.
  - **Cache:** for LLM calls, `hit_rate` = cached tokens / input tokens, and
    `hit_share` = share of calls with more than 128 cached tokens. xAI reports
    128 cached tokens even when it reused nothing, so 128 is the floor, not a hit.
  - **Idle gap:** for each GM call, the time from the end of the previous xAI
    call on the same `x-grok-conv-id` to the start of this one (nil for the
    first call on that id). Rows recorded before `conv_id` / `started_at`
    existed use the current conv-id rule and `inserted_at - latency_ms`
    (second precision).

  Percentiles use linear interpolation, like Postgres `percentile_cont`, so the
  Elixir (per session) and SQL (per period) figures agree.
  """

  import Ecto.Query

  alias TalesForge.AICalls
  alias TalesForge.Repo
  alias TalesForge.Schemas.AICall

  @cache_floor 128
  @narration_purposes ~w(scene gm)
  @section_order %{"game" => 0, "persona" => 1, "scorer" => 2}
  @type_order %{"llm" => 0, "jev" => 1, "function" => 2}
  @recent_sessions 10

  def cache_floor, do: @cache_floor

  # ---------------------------------------------------------------------------
  # Pure helpers (rows are AICall structs or maps with the same keys)

  @doc "Linear-interpolated percentile (0.0..1.0) of a list of numbers; nil when empty."
  def percentile([], _p), do: nil

  def percentile(values, p) when is_list(values) and p >= 0 and p <= 1 do
    sorted = values |> Enum.sort() |> List.to_tuple()
    rank = p * (tuple_size(sorted) - 1)
    lo = floor(rank)
    hi = ceil(rank)
    low = elem(sorted, lo)
    (low + (elem(sorted, hi) - low) * (rank - lo)) / 1
  end

  @doc "True when a call reused more of the prompt cache than the 128-token floor."
  def hit?(row), do: (row.cached_tokens || 0) > @cache_floor

  @doc """
  Cache figures for the LLM calls in `rows` that report input tokens:
  `calls`, `input_tokens`, `cached_tokens`, `hit_rate` (cached / input),
  `hits` (calls over the floor) and `hit_share` (hits / calls). Rates are nil
  without calls.
  """
  def cache(rows) do
    rows =
      Enum.filter(
        rows,
        &(&1.call_type == "llm" and is_integer(&1.input_tokens) and &1.input_tokens > 0)
      )

    input = rows |> Enum.map(& &1.input_tokens) |> Enum.sum()
    cached = rows |> Enum.map(&(&1.cached_tokens || 0)) |> Enum.sum()
    hits = Enum.count(rows, &hit?/1)
    calls = length(rows)

    %{
      calls: calls,
      input_tokens: input,
      cached_tokens: cached,
      hit_rate: ratio(cached, input),
      hits: hits,
      hit_share: ratio(hits, calls)
    }
  end

  @doc """
  The conv id a call was (or, for old rows, would have been) sent with:
  `conv_id` when recorded, else the bare session id for scene/GM calls and
  `<session>:<purpose>` for the rest. Nil without a session.
  """
  def conv_key(%{conv_id: conv}) when is_binary(conv) and conv != "", do: conv
  def conv_key(%{game_session_id: nil}), do: nil
  def conv_key(%{game_session_id: sid, purpose: p}) when p in @narration_purposes, do: sid
  def conv_key(%{game_session_id: sid, purpose: p}), do: "#{sid}:#{p}"

  @doc "Start of a call in Unix milliseconds (`started_at`, else `inserted_at - latency_ms`)."
  def started_ms(%{started_at: %DateTime{} = at}), do: DateTime.to_unix(at, :microsecond) / 1_000

  def started_ms(%{inserted_at: %DateTime{} = at, latency_ms: ms}),
    do: DateTime.to_unix(at, :millisecond) - (ms || 0)

  def started_ms(%{inserted_at: %NaiveDateTime{} = at} = row),
    do: started_ms(%{row | inserted_at: DateTime.from_naive!(at, "Etc/UTC")})

  @doc """
  One entry per GM call in `rows`, in time order: `turn_number`, `gap_ms` (idle
  time since the previous xAI call on the same conv id ended; nil for the first),
  `hit` and `cached_tokens`. Capped calls never reached xAI and are skipped.
  """
  def idle_gaps(rows) do
    rows
    |> Enum.filter(&(&1.call_type == "llm" and &1.status != "capped" and conv_key(&1) != nil))
    |> Enum.sort_by(&started_ms/1)
    |> Enum.group_by(&conv_key/1)
    |> Enum.flat_map(fn {_conv, calls} -> gaps_on_conv(calls) end)
    |> Enum.filter(&(&1.purpose == "gm"))
    |> Enum.sort_by(& &1.started_ms)
    |> Enum.map(&Map.drop(&1, [:purpose, :started_ms]))
  end

  defp gaps_on_conv(calls) do
    {entries, _prev_end} =
      Enum.map_reduce(calls, nil, fn call, prev_end ->
        start = started_ms(call)

        entry = %{
          purpose: call.purpose,
          started_ms: start,
          turn_number: call.turn_number,
          gap_ms: if(prev_end, do: round(start - prev_end)),
          hit: hit?(call),
          cached_tokens: call.cached_tokens
        }

        {entry, start + (call.latency_ms || 0)}
      end)

    entries
  end

  @doc "Count, cost (total, average) and p50/p90 latency of `rows`."
  def summarize(rows) do
    calls = length(rows)
    cost = rows |> Enum.map(&(&1.cost_micro_usd || 0)) |> Enum.sum()
    latencies = Enum.map(rows, &(&1.latency_ms || 0))

    %{
      calls: calls,
      cost_micro_usd: cost,
      avg_cost_micro_usd: if(calls > 0, do: div(cost, calls)),
      p50_ms: percentile(latencies, 0.5),
      p90_ms: percentile(latencies, 0.9),
      latency_ms: Enum.sum(latencies),
      input_tokens: rows |> Enum.map(&(&1.input_tokens || 0)) |> Enum.sum(),
      output_tokens: rows |> Enum.map(&(&1.output_tokens || 0)) |> Enum.sum(),
      cached_tokens: rows |> Enum.map(&(&1.cached_tokens || 0)) |> Enum.sum(),
      capped: Enum.count(rows, &(&1.status == "capped")),
      errors: Enum.count(rows, &(&1.status == "error"))
    }
  end

  @doc ~s[Spend section of a row: "game", or the bot purpose ("persona", "scorer").]
  def section(%{purpose: purpose}), do: AICalls.bucket(purpose)

  @doc "`summarize/1` per `{section, call_type, purpose}`, sorted game → persona → scorer."
  def breakdown(rows) do
    rows
    |> Enum.group_by(&{section(&1), &1.call_type, &1.purpose})
    |> Enum.map(fn {{section, type, purpose}, group} ->
      Map.merge(summarize(group), %{section: section, call_type: type, purpose: purpose})
    end)
    |> sort_breakdown()
  end

  defp sort_breakdown(rows) do
    Enum.sort_by(rows, fn row ->
      {Map.get(@section_order, row.section, 9), Map.get(@type_order, row.call_type, 9),
       row.purpose}
    end)
  end

  # ---------------------------------------------------------------------------
  # One session (playtest run reports)

  @doc """
  Everything a run report shows for one session: the breakdown, section totals
  (function rows count toward time, never cost), per-turn rows, cache figures
  for GM calls (all, and turns 2+) and all game LLM calls, and GM idle gaps.
  """
  def session_report(session_id) do
    rows =
      AICall
      |> where([c], c.game_session_id == ^session_id)
      |> order_by([c], asc: c.inserted_at, asc: c.started_at)
      |> Repo.all()

    session_report_from_rows(rows)
  end

  @doc false
  def session_report_from_rows(rows) do
    by_section = Enum.group_by(rows, &section/1)
    game = Map.get(by_section, "game", [])
    game_calls = Enum.reject(game, &(&1.call_type == "function"))
    gm = Enum.filter(game_calls, &(&1.purpose == "gm" and &1.call_type == "llm"))
    gaps = idle_gaps(rows)
    turns = gm |> Enum.map(& &1.turn_number) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    game_total = summarize(game_calls)

    turn_counts = %{
      "game" => length(turns),
      "persona" => count_turns(Map.get(by_section, "persona", [])),
      "scorer" => 0
    }

    %{
      breakdown: rows |> breakdown() |> Enum.map(&put_per_turn(&1, turn_counts)),
      game: game_total,
      persona: summarize(Map.get(by_section, "persona", [])),
      scorer: summarize(Map.get(by_section, "scorer", [])),
      turns: length(turns),
      game_cost_per_turn: if(turns != [], do: div(game_total.cost_micro_usd, length(turns))),
      gm: summarize(gm),
      cache: %{
        gm: cache(gm),
        gm_later: cache(Enum.filter(gm, &((&1.turn_number || 0) >= 2))),
        game: cache(game_calls)
      },
      idle_gap: %{
        p50_ms: gaps |> Enum.map(& &1.gap_ms) |> Enum.reject(&is_nil/1) |> percentile(0.5),
        p90_ms: gaps |> Enum.map(& &1.gap_ms) |> Enum.reject(&is_nil/1) |> percentile(0.9)
      },
      per_turn: per_turn(rows, gaps)
    }
  end

  defp count_turns(rows),
    do: rows |> Enum.map(& &1.turn_number) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length()

  defp put_per_turn(row, turn_counts) do
    turns = Map.get(turn_counts, row.section, 0)
    Map.put(row, :per_turn_micro_usd, if(turns > 0, do: div(row.cost_micro_usd, turns)))
  end

  defp per_turn(rows, gaps) do
    gap_by_turn = gaps |> Enum.reverse() |> Map.new(&{&1.turn_number, &1.gap_ms})

    rows
    |> Enum.filter(&is_integer(&1.turn_number))
    |> Enum.group_by(& &1.turn_number)
    |> Enum.sort_by(fn {turn, _} -> turn end)
    |> Enum.map(fn {turn, turn_rows} -> turn_row(turn, turn_rows, gap_by_turn) end)
  end

  defp turn_row(turn, rows, gap_by_turn) do
    gm =
      rows
      |> Enum.filter(&(&1.call_type == "llm" and &1.purpose == "gm"))
      |> summarize()

    game =
      Enum.filter(rows, &(section(&1) == "game" and &1.call_type != "function"))

    %{
      turn_number: turn,
      gm_calls: gm.calls,
      gm_latency_ms: gm.latency_ms,
      gm_input_tokens: gm.input_tokens,
      gm_cached_tokens: gm.cached_tokens,
      gm_output_tokens: gm.output_tokens,
      gm_cost_micro_usd: gm.cost_micro_usd,
      gm_hit: gm.calls > 0 and gm.cached_tokens > @cache_floor,
      idle_gap_ms: Map.get(gap_by_turn, turn),
      game_cost_micro_usd: game |> Enum.map(&(&1.cost_micro_usd || 0)) |> Enum.sum(),
      persona_cost_micro_usd:
        rows
        |> Enum.filter(&(section(&1) == "persona"))
        |> Enum.map(&(&1.cost_micro_usd || 0))
        |> Enum.sum(),
      steps:
        rows
        |> Enum.filter(&(&1.call_type == "function"))
        |> Map.new(&{String.replace_prefix(&1.purpose, "turn.", ""), &1.latency_ms})
    }
  end

  # ---------------------------------------------------------------------------
  # A period (admin costs page), aggregated in SQL

  @doc """
  The costs page's metrics for calls inserted in `[from, to]` (UTC):
  `:breakdown` (as `breakdown/1`, plus per-session and per-turn cost per row),
  `:counts` (sessions and turns per section), `:cache` (GM, GM turns 2+, all game
  LLM calls), `:idle_gap` (GM p50/p90), `:player_quote` (as `player_quote/2`)
  and `:sessions` (the most recent ones).
  """
  def period(%DateTime{} = from, %DateTime{} = to) do
    {from, to} = {DateTime.truncate(from, :second), DateTime.truncate(to, :second)}
    base = where(AICall, [c], c.inserted_at >= ^from and c.inserted_at <= ^to)
    counts = period_counts(base)

    breakdown =
      base
      |> group_by([c], [c.call_type, c.purpose])
      |> select([c], %{
        call_type: c.call_type,
        purpose: c.purpose,
        calls: count(c.id),
        cost_micro_usd: type(coalesce(sum(c.cost_micro_usd), 0), :integer),
        p50_ms: fragment("percentile_cont(0.5) WITHIN GROUP (ORDER BY ?)", c.latency_ms),
        p90_ms: fragment("percentile_cont(0.9) WITHIN GROUP (ORDER BY ?)", c.latency_ms),
        capped: filter(count(c.id), c.status == "capped"),
        errors: filter(count(c.id), c.status == "error")
      })
      |> Repo.all()
      |> Enum.map(&period_row(&1, counts))
      |> sort_breakdown()

    %{
      breakdown: breakdown,
      counts: counts,
      cache: %{
        gm: period_cache(where(base, [c], c.purpose == "gm")),
        gm_later: period_cache(where(base, [c], c.purpose == "gm" and c.turn_number >= 2)),
        game: period_cache(where(base, [c], c.purpose not in ^AICalls.bot_purposes()))
      },
      idle_gap: period_idle_gap(from, to),
      player_quote: player_quote_counts(base),
      sessions: recent_sessions(base)
    }
  end

  @doc """
  The input safety reads (`TalesForge.Game.PlayerQuote`, purpose
  `input_safety`) inserted in `[from, to]` (UTC): `:reads`, `:quotes` (the GM
  got the player's own words), `:fallbacks` (the intent summary),
  `:fallback_rate` (nil without reads) and `:reasons` (fallback reason →
  count, e.g. `"low_confidence"`, `"label_prompt_injection"`, `"unconfigured"`).
  """
  def player_quote(%DateTime{} = from, %DateTime{} = to) do
    {from, to} = {DateTime.truncate(from, :second), DateTime.truncate(to, :second)}
    player_quote_counts(where(AICall, [c], c.inserted_at >= ^from and c.inserted_at <= ^to))
  end

  defp player_quote_counts(base) do
    reasons =
      base
      |> where([c], c.purpose == "input_safety")
      |> group_by([c], [fragment("?->>'used'", c.meta), fragment("?->>'reason'", c.meta)])
      |> select(
        [c],
        {fragment("?->>'used'", c.meta), fragment("?->>'reason'", c.meta), count(c.id)}
      )
      |> Repo.all()

    quotes = for {"quote", _reason, n} <- reasons, reduce: 0, do: (acc -> acc + n)
    reads = Enum.reduce(reasons, 0, fn {_used, _reason, n}, acc -> acc + n end)
    fallbacks = reads - quotes

    %{
      reads: reads,
      quotes: quotes,
      fallbacks: fallbacks,
      fallback_rate: if(reads > 0, do: fallbacks / reads),
      reasons:
        for({used, reason, n} <- reasons, used != "quote", do: {reason || "unknown", n})
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Map.new(fn {reason, ns} -> {reason, Enum.sum(ns)} end)
    }
  end

  defp period_row(row, counts) do
    section = AICalls.bucket(row.purpose)
    %{sessions: sessions, turns: turns} = Map.fetch!(counts, section)

    Map.merge(row, %{
      section: section,
      avg_cost_micro_usd: if(row.calls > 0, do: div(row.cost_micro_usd, row.calls)),
      per_session_micro_usd: if(sessions > 0, do: div(row.cost_micro_usd, sessions)),
      per_turn_micro_usd: if(turns > 0, do: div(row.cost_micro_usd, turns))
    })
  end

  # Sessions and turns per section. A game turn is a (session, turn) with a GM
  # call; persona turns are (session, turn) pairs with a persona call.
  defp period_counts(base) do
    count_pairs = fn query ->
      query
      |> where([c], not is_nil(c.game_session_id))
      |> select([c], %{
        sessions: count(c.game_session_id, :distinct),
        turns:
          fragment(
            "count(DISTINCT (?, ?)) FILTER (WHERE ? IS NOT NULL)",
            c.game_session_id,
            c.turn_number,
            c.turn_number
          )
      })
      |> Repo.one()
    end

    game_sessions =
      base
      |> where([c], c.purpose not in ^AICalls.bot_purposes() and c.call_type != "function")
      |> count_pairs.()

    game_turns = base |> where([c], c.purpose == "gm" and c.call_type == "llm") |> count_pairs.()

    %{
      "game" => %{sessions: game_sessions.sessions, turns: game_turns.turns},
      "persona" => base |> where([c], c.purpose == "persona") |> count_pairs.(),
      "scorer" => base |> where([c], c.purpose == "scorer") |> count_pairs.()
    }
  end

  defp period_cache(query) do
    query
    |> where([c], c.call_type == "llm" and c.input_tokens > 0)
    |> select([c], %{
      calls: count(c.id),
      input_tokens: type(coalesce(sum(c.input_tokens), 0), :integer),
      cached_tokens: type(coalesce(sum(c.cached_tokens), 0), :integer),
      hits: filter(count(c.id), c.cached_tokens > @cache_floor)
    })
    |> Repo.one()
    |> then(fn c ->
      Map.merge(c, %{
        hit_rate: ratio(c.cached_tokens, c.input_tokens),
        hit_share: ratio(c.hits, c.calls)
      })
    end)
  end

  # Window over xAI calls per conv id: gap = this start - previous end. Calls
  # of the period only (a GM call right after `from` has no previous call).
  @idle_gap_sql """
  WITH calls AS (
    SELECT purpose,
           COALESCE(conv_id,
                    CASE WHEN purpose IN ('scene', 'gm') THEN game_session_id::text
                         ELSE game_session_id::text || ':' || purpose END) AS conv,
           COALESCE(started_at, inserted_at - make_interval(secs => latency_ms / 1000.0)) AS t0,
           latency_ms
    FROM ai_calls
    WHERE call_type = 'llm' AND status <> 'capped' AND game_session_id IS NOT NULL
      AND inserted_at >= $1 AND inserted_at <= $2
  ), gaps AS (
    SELECT purpose,
           EXTRACT(EPOCH FROM t0 - LAG(t0 + make_interval(secs => latency_ms / 1000.0))
                                     OVER (PARTITION BY conv ORDER BY t0)) * 1000 AS gap_ms
    FROM calls
  )
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY gap_ms)::float8,
         percentile_cont(0.9) WITHIN GROUP (ORDER BY gap_ms)::float8,
         count(gap_ms)
  FROM gaps WHERE purpose = 'gm' AND gap_ms IS NOT NULL
  """

  defp period_idle_gap(from, to) do
    naive = &DateTime.to_naive/1
    %{rows: [[p50, p90, n]]} = Repo.query!(@idle_gap_sql, [naive.(from), naive.(to)])
    %{p50_ms: p50, p90_ms: p90, calls: n}
  end

  defp recent_sessions(base) do
    bots = AICalls.bot_purposes()

    base
    |> where([c], not is_nil(c.game_session_id))
    |> group_by([c], c.game_session_id)
    |> order_by([c], desc: max(c.inserted_at))
    |> limit(@recent_sessions)
    |> select([c], %{
      game_session_id: c.game_session_id,
      last_at: max(c.inserted_at),
      adventure_id: max(c.adventure_id),
      game_cost_micro_usd:
        type(coalesce(filter(sum(c.cost_micro_usd), c.purpose not in ^bots), 0), :integer),
      persona_cost_micro_usd:
        type(coalesce(filter(sum(c.cost_micro_usd), c.purpose == "persona"), 0), :integer),
      turns:
        fragment(
          "count(DISTINCT ?) FILTER (WHERE ? = 'gm' AND ? = 'llm')",
          c.turn_number,
          c.purpose,
          c.call_type
        ),
      gm_p50_ms:
        fragment(
          "percentile_cont(0.5) WITHIN GROUP (ORDER BY ?) FILTER (WHERE ? = 'gm' AND ? = 'llm')",
          c.latency_ms,
          c.purpose,
          c.call_type
        ),
      gm_calls: filter(count(c.id), c.purpose == "gm" and c.call_type == "llm"),
      gm_input: type(coalesce(filter(sum(c.input_tokens), c.purpose == "gm"), 0), :integer),
      gm_cached: type(coalesce(filter(sum(c.cached_tokens), c.purpose == "gm"), 0), :integer),
      gm_hits: filter(count(c.id), c.purpose == "gm" and c.cached_tokens > @cache_floor)
    })
    |> Repo.all()
    |> Enum.map(fn s ->
      Map.merge(s, %{
        gm_hit_rate: ratio(s.gm_cached, s.gm_input),
        gm_hit_share: ratio(s.gm_hits, s.gm_calls),
        game_cost_per_turn: if(s.turns > 0, do: div(s.game_cost_micro_usd, s.turns))
      })
    end)
  end

  defp ratio(_num, 0), do: nil
  defp ratio(_num, nil), do: nil
  defp ratio(num, den), do: num / den
end
