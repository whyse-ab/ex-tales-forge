defmodule TalesForge.AICalls.MetricsTest do
  use TalesForge.DataCase, async: true

  alias TalesForge.AICalls.Metrics
  alias TalesForge.GameSessions
  alias TalesForge.Schemas.AICall

  @t0 ~U[2026-10-07 07:47:10.000000Z]

  # A call starting `start_ms` after @t0.
  defp call(sid, purpose, start_ms, latency_ms, attrs) do
    started_at = DateTime.add(@t0, start_ms, :millisecond)

    struct!(
      AICall,
      Map.merge(
        %{
          game_session_id: sid,
          purpose: purpose,
          call_type: "llm",
          model: "xai/grok-4.20-0309-non-reasoning",
          status: "ok",
          latency_ms: latency_ms,
          started_at: started_at,
          inserted_at:
            started_at |> DateTime.add(latency_ms, :millisecond) |> DateTime.truncate(:second),
          conv_id: if(purpose in ~w(scene gm), do: sid, else: "#{sid}:#{purpose}"),
          cost_micro_usd: 0
        },
        Map.new(attrs)
      )
    )
  end

  defp step(sid, purpose, turn, latency_ms),
    do:
      call(sid, purpose, 0, latency_ms, %{
        call_type: "function",
        model: "elixir",
        conv_id: nil,
        turn_number: turn
      })

  # Scene, then per turn: persona (own conv id), GM; turn 2's GM hits the cache.
  defp paul_session(sid) do
    [
      call(sid, "scene", 0, 2_000,
        cost_micro_usd: 10_000,
        input_tokens: 8_197,
        cached_tokens: 128
      ),
      call(sid, "persona", 2_100, 900,
        turn_number: 1,
        cost_micro_usd: 1_000,
        input_tokens: 900,
        cached_tokens: 128
      ),
      call(sid, "gm", 3_500, 4_000,
        turn_number: 1,
        cost_micro_usd: 12_000,
        input_tokens: 9_000,
        cached_tokens: 128,
        output_tokens: 300
      ),
      call(sid, "persona", 7_600, 1_200,
        turn_number: 2,
        cost_micro_usd: 1_400,
        input_tokens: 1_100,
        cached_tokens: 576
      ),
      call(sid, "gm", 9_000, 5_000,
        turn_number: 2,
        cost_micro_usd: 4_000,
        input_tokens: 9_200,
        cached_tokens: 8_320,
        output_tokens: 350
      ),
      step(sid, "turn.rules", 2, 12),
      step(sid, "turn.persist", 2, 30),
      call(sid, "scorer", 15_000, 300,
        call_type: "jev",
        model: "jev-1.13.0",
        conv_id: nil,
        cost_micro_usd: 100,
        input_tokens: 2_500
      )
    ]
    |> Enum.map(fn c -> Map.update!(c, :cost_micro_usd, &(&1 || 0)) end)
  end

  describe "percentile/2 (Postgres percentile_cont semantics)" do
    test "interpolates linearly" do
      assert Metrics.percentile([1, 2, 3, 4], 0.5) == 2.5
      assert_in_delta Metrics.percentile([1, 2, 3, 4], 0.9), 3.7, 1.0e-9
      assert Metrics.percentile([4_400], 0.9) == 4_400.0
      assert Metrics.percentile([], 0.5) == nil
    end
  end

  describe "cache/1" do
    test "hit rate is cached / input; a hit needs more than the 128-token floor" do
      sid = Ecto.UUID.generate()
      rows = paul_session(sid)
      gm = Enum.filter(rows, &(&1.purpose == "gm"))

      assert %{calls: 2, hits: 1, hit_share: 0.5, input_tokens: 18_200, cached_tokens: 8_448} =
               c = Metrics.cache(gm)

      assert_in_delta c.hit_rate, 8_448 / 18_200, 1.0e-9

      # Function and Jev rows never count; no calls means no rates.
      assert Metrics.cache(Enum.reject(rows, &(&1.call_type == "llm"))) ==
               %{
                 calls: 0,
                 input_tokens: 0,
                 cached_tokens: 0,
                 hit_rate: nil,
                 hits: 0,
                 hit_share: nil
               }
    end
  end

  describe "idle_gaps/1" do
    test "measures from the previous call on the same conv id; persona calls don't count" do
      sid = Ecto.UUID.generate()

      # GM1 starts 1.5 s after the scene ended (persona ran on its own conv id
      # in between); GM2 starts 1.5 s after GM1 ended.
      assert [
               %{turn_number: 1, gap_ms: 1_500, hit: false},
               %{turn_number: 2, gap_ms: 1_500, hit: true, cached_tokens: 8_320}
             ] = Metrics.idle_gaps(paul_session(sid))
    end

    test "a persona call on the session id (before #37) does shorten the GM gap" do
      sid = Ecto.UUID.generate()

      rows = [
        call(sid, "gm", 0, 4_000, turn_number: 1),
        call(sid, "persona", 4_500, 1_000, turn_number: 2, conv_id: sid),
        call(sid, "gm", 6_000, 4_000, turn_number: 2)
      ]

      assert [%{gap_ms: nil}, %{gap_ms: 500}] = Metrics.idle_gaps(rows)
    end

    test "old rows without conv_id/started_at use the current rule and inserted_at - latency" do
      sid = Ecto.UUID.generate()

      old = fn purpose, inserted_at, latency, turn ->
        struct!(AICall,
          game_session_id: sid,
          purpose: purpose,
          call_type: "llm",
          status: "ok",
          latency_ms: latency,
          inserted_at: inserted_at,
          turn_number: turn
        )
      end

      rows = [
        old.("gm", ~U[2026-10-07 07:00:05Z], 4_000, 1),
        old.("persona", ~U[2026-10-07 07:00:07Z], 1_000, 2),
        old.("gm", ~U[2026-10-07 07:00:12Z], 4_000, 2),
        old.("gm", ~U[2026-10-07 07:00:20Z], 4_000, 3) |> Map.put(:status, "capped")
      ]

      assert [%{gap_ms: nil}, %{turn_number: 2, gap_ms: 3_000}] = Metrics.idle_gaps(rows)
    end
  end

  describe "session_report_from_rows/1" do
    test "breakdown keeps persona and scorer apart from game; function rows cost nothing" do
      sid = Ecto.UUID.generate()
      report = Metrics.session_report_from_rows(paul_session(sid))

      assert Enum.map(report.breakdown, &{&1.section, &1.call_type, &1.purpose, &1.calls}) == [
               {"game", "llm", "gm", 2},
               {"game", "llm", "scene", 1},
               {"game", "function", "turn.persist", 1},
               {"game", "function", "turn.rules", 1},
               {"persona", "llm", "persona", 2},
               {"scorer", "jev", "scorer", 1}
             ]

      gm = Enum.find(report.breakdown, &(&1.purpose == "gm"))

      assert {gm.cost_micro_usd, gm.avg_cost_micro_usd, gm.p50_ms, gm.p90_ms} ==
               {16_000, 8_000, 4_500.0, 4_900.0}

      # 2 GM turns: game cost per turn and per-turn cost per row.
      assert gm.per_turn_micro_usd == 8_000
      assert Enum.find(report.breakdown, &(&1.purpose == "persona")).per_turn_micro_usd == 1_200

      # Game total: gm + scene only (no persona, no scorer, function rows not calls).
      assert {report.game.calls, report.game.cost_micro_usd} == {3, 26_000}
      assert {report.persona.calls, report.persona.cost_micro_usd} == {2, 2_400}
      assert report.scorer.cost_micro_usd == 100
      assert {report.turns, report.game_cost_per_turn} == {2, 13_000}

      assert %{calls: 1, hits: 1} = report.cache.gm_later
      assert %{calls: 2, hits: 1} = report.cache.gm
      assert %{calls: 3, hits: 1} = report.cache.game
      assert report.idle_gap == %{p50_ms: 1_500.0, p90_ms: 1_500.0}
    end

    test "per-turn rows: GM figures, idle gap, hit, game vs persona cost and step timings" do
      sid = Ecto.UUID.generate()

      assert [t1, t2] = Metrics.session_report_from_rows(paul_session(sid)).per_turn

      assert %{turn_number: 1, gm_hit: false, idle_gap_ms: 1_500, gm_cost_micro_usd: 12_000} = t1
      assert {t1.game_cost_micro_usd, t1.persona_cost_micro_usd} == {12_000, 1_000}

      assert %{
               turn_number: 2,
               gm_hit: true,
               gm_latency_ms: 5_000,
               gm_input_tokens: 9_200,
               gm_cached_tokens: 8_320,
               gm_output_tokens: 350,
               game_cost_micro_usd: 4_000,
               persona_cost_micro_usd: 1_400,
               steps: %{"rules" => 12, "persist" => 30}
             } = t2
    end
  end

  describe "period/2 (SQL)" do
    test "matches the Elixir figures and adds per-session / per-turn cost" do
      {:ok, a} = GameSessions.create_session(%{name: "A", adventure_id: "tin_valley"})
      {:ok, b} = GameSessions.create_session(%{name: "B", adventure_id: "tin_valley"})

      rows = paul_session(a.id) ++ paul_session(b.id)
      Enum.each(rows, &Repo.insert!(%{&1 | adventure_id: "tin_valley"}))

      from = DateTime.add(@t0, -60)
      to = DateTime.add(@t0, 3_600)
      period = Metrics.period(from, to)

      assert period.counts["game"] == %{sessions: 2, turns: 4}
      assert period.counts["persona"] == %{sessions: 2, turns: 4}

      gm = Enum.find(period.breakdown, &(&1.purpose == "gm"))
      elixir_gm = rows |> Enum.filter(&(&1.purpose == "gm")) |> Metrics.summarize()

      assert gm.calls == 4
      assert gm.cost_micro_usd == 32_000
      assert {gm.p50_ms, gm.p90_ms} == {elixir_gm.p50_ms, elixir_gm.p90_ms}
      assert {gm.per_session_micro_usd, gm.per_turn_micro_usd} == {16_000, 8_000}

      persona = Enum.find(period.breakdown, &(&1.purpose == "persona"))
      assert {persona.section, persona.per_session_micro_usd} == {"persona", 2_400}

      assert Enum.map(period.breakdown, & &1.section) |> Enum.dedup() ==
               ~w(game persona scorer)

      assert %{calls: 2, hits: 2} = period.cache.gm_later
      assert %{calls: 4, hits: 2, hit_share: 0.5} = period.cache.gm
      assert %{calls: 6} = period.cache.game

      assert period.idle_gap == %{p50_ms: 1_500.0, p90_ms: 1_500.0, calls: 4}

      assert [s1, s2] = period.sessions
      assert Enum.sort([s1.game_session_id, s2.game_session_id]) == Enum.sort([a.id, b.id])

      assert %{
               adventure_id: "tin_valley",
               turns: 2,
               game_cost_micro_usd: 26_000,
               persona_cost_micro_usd: 2_400,
               game_cost_per_turn: 13_000,
               gm_hits: 1,
               gm_calls: 2,
               gm_hit_share: 0.5
             } = s1

      assert s1.gm_p50_ms == 4_500.0
    end

    test "is empty-safe" do
      period = Metrics.period(DateTime.add(@t0, -10), @t0)
      assert period.breakdown == []
      assert period.sessions == []
      assert period.cache.gm.hit_rate == nil
      assert period.idle_gap == %{p50_ms: nil, p90_ms: nil, calls: 0}
    end
  end
end
