defmodule TalesForge.CostsTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.AICalls
  alias TalesForge.Costs
  alias TalesForge.Costs.Peer
  alias TalesForge.Costs.PlaytestRuns
  alias TalesForge.GameSessions
  alias TalesForge.Schemas.AICall

  # 2026-10-15 12:00 in Stockholm (CEST, UTC+2): day starts 2026-10-14 22:00Z,
  # month starts 2026-09-30 22:00Z.
  @now ~U[2026-10-15 10:00:00Z]

  setup do
    on_exit(fn ->
      Application.delete_env(:ex_tales_forge, :costs_peer)
      Application.delete_env(:ex_tales_forge, :app_name)
    end)

    :ok
  end

  describe "buckets" do
    test "game is every purpose that isn't a bot purpose" do
      assert AICalls.buckets() == ["game", "persona", "scorer"]
      assert AICalls.bucket("gm") == "game"
      assert AICalls.bucket("intent") == "game"
      assert AICalls.bucket("scene") == "game"
      assert AICalls.bucket("persona") == "persona"
      assert AICalls.bucket("scorer") == "scorer"
    end

    test "spend_by_bucket sums calls, cost, capped and errors per bucket" do
      insert!("gm", 1_000, ~U[2026-10-15 09:00:00Z])
      insert!("intent", 200, ~U[2026-10-15 09:00:00Z])
      insert!("scene", 300, ~U[2026-10-15 09:00:00Z], status: "error")
      insert!("gm", nil, ~U[2026-10-15 09:00:00Z], status: "capped")
      insert!("persona", 50, ~U[2026-10-15 09:00:00Z])
      insert!("persona", 0, ~U[2026-10-15 09:00:00Z], status: "capped")

      assert AICalls.spend_by_bucket(~U[2026-10-15 00:00:00Z], @now) == %{
               "game" => %{calls: 4, cost_micro_usd: 1_500, capped: 1, errors: 1},
               "persona" => %{calls: 2, cost_micro_usd: 50, capped: 1, errors: 0},
               "scorer" => %{calls: 0, cost_micro_usd: 0, capped: 0, errors: 0}
             }
    end
  end

  describe "time windows (Europe/Stockholm)" do
    test "month_start is the Stockholm calendar month, across DST" do
      assert AICalls.month_start(@now) == ~U[2026-09-30 22:00:00Z]
      assert AICalls.month_start(~U[2026-09-30 21:59:59Z]) == ~U[2026-08-31 22:00:00Z]
      assert AICalls.month_start(~U[2026-09-30 22:00:00Z]) == ~U[2026-09-30 22:00:00Z]
      # November starts in CET (UTC+1)
      assert AICalls.month_start(~U[2026-11-10 12:00:00Z]) == ~U[2026-10-31 23:00:00Z]
    end

    test "today starts at Stockholm midnight and the month at the 1st, Stockholm time" do
      insert!("gm", 1, ~U[2026-10-14 21:59:59Z])
      insert!("gm", 10, ~U[2026-10-14 22:00:00Z])
      insert!("scorer", 100, ~U[2026-10-15 09:59:00Z])
      insert!("gm", 1_000, ~U[2026-09-30 21:59:59Z])
      insert!("gm", 10_000, ~U[2026-09-30 22:00:00Z])
      # exactly "now" counts; after "now" doesn't
      insert!("gm", 100_000, ~U[2026-10-15 10:00:00Z])
      insert!("gm", 1_000_000, ~U[2026-10-15 10:00:01Z])

      summary = Costs.ai_summary(@now)

      assert summary["today"]["since"] == "2026-10-14T22:00:00Z"

      assert summary["today"]["buckets"]["game"] == %{
               "calls" => 2,
               "cost_micro_usd" => 100_010,
               "capped" => 0,
               "errors" => 0
             }

      assert summary["today"]["buckets"]["scorer"]["cost_micro_usd"] == 100

      assert summary["month"]["since"] == "2026-09-30T22:00:00Z"
      assert summary["month"]["buckets"]["game"]["calls"] == 4
      assert summary["month"]["buckets"]["game"]["cost_micro_usd"] == 110_011
      assert summary["month"]["total_micro_usd"] == 110_111
      assert summary["date"] == "2026-10-15"
    end

    test "average game cost per game session this month, bots left out" do
      {:ok, a} = GameSessions.create_session(%{name: "Costs A"})
      {:ok, b} = GameSessions.create_session(%{name: "Costs B"})
      {:ok, bot_only} = GameSessions.create_session(%{name: "Costs bot only"})

      insert!("gm", 3_000, ~U[2026-10-10 10:00:00Z], session: a)
      insert!("scene", 1_000, ~U[2026-10-10 10:00:00Z], session: a)
      insert!("gm", 2_000, ~U[2026-10-11 10:00:00Z], session: b)
      insert!("persona", 9_000, ~U[2026-10-11 10:00:00Z], session: bot_only)
      # last month: not counted
      insert!("gm", 50_000, ~U[2026-09-20 10:00:00Z], session: bot_only)

      month = Costs.ai_summary(@now)["month"]
      assert month["game_sessions"] == 2
      assert month["avg_game_micro_usd_per_session"] == 3_000
    end

    test "no game sessions means no average" do
      assert Costs.ai_summary(@now)["month"]["avg_game_micro_usd_per_session"] == nil
    end

    test "month-end projection is spend / days elapsed * days in month" do
      insert!("gm", 1_500_000, ~U[2026-10-02 10:00:00Z])

      summary = Costs.ai_summary(@now)
      assert summary["day_of_month"] == 15
      assert summary["days_in_month"] == 31
      assert summary["month"]["projected_micro_usd"] == 3_100_000
    end
  end

  describe "report" do
    @fixed [
      %{name: "App", env: :production, amount: {:usd_per_month, 6.95}, source: "a"},
      %{name: "Playtest app", env: :playtest, amount: {:usd_per_month, 3.84}, source: "b"},
      %{name: "Playtest db", env: :playtest, amount: {:usd_per_month, 3.99}, source: "c"},
      %{name: "Domain", env: :shared, amount: :unknown, source: "d"}
    ]

    test "playtest unavailable: the grand total is production's alone" do
      local = summary("tales-forge", 1_000_000, 15, 30)

      for playtest <- [{:error, :not_configured}, {:error, :unreachable}, {:error, :loading}] do
        report = Costs.report(local, playtest, @fixed)

        refute report.playtest_included
        assert report.production_month_micro_usd == 1_000_000
        assert report.grand_month_micro_usd == 1_000_000
        assert report.grand_projected_micro_usd == 2_000_000
        assert report.playtest_runs_month_micro_usd == nil
        assert report.playtest.status == :unavailable
      end
    end

    test "unknown fixed items are listed; fixed costs stay out of the grand total" do
      report =
        Costs.report(summary("tales-forge", 1_000_000, 15, 30), {:error, :unreachable}, @fixed)

      assert report.unknown == ["Domain"]
      assert report.fixed_known_micro_usd == 14_780_000
      assert report.grand_month_micro_usd == 1_000_000
    end

    test "grand total: production + playtest runs + playtest outside runs" do
      local = summary("tales-forge", 1_000_000, 15, 30)
      playtest = playtest_summary(game: 2_500_000, persona: 1_000_000, outside: 500_000)

      report = Costs.report(local, {:ok, playtest}, @fixed)
      assert report.playtest_included
      assert report.playtest_game_month_micro_usd == 2_500_000
      assert report.playtest_bots_month_micro_usd == 1_000_000
      assert report.playtest_runs_month_micro_usd == 3_500_000
      assert report.playtest_outside_month_micro_usd == 500_000
      assert report.grand_month_micro_usd == 5_000_000
      # 15 of 30 days: production 2.00 + playtest 8.00
      assert report.playtest_projected_micro_usd == 8_000_000
      assert report.grand_projected_micro_usd == 10_000_000

      # 3.84 + 3.99 + 8.00 projected = 15.83 > 15
      assert %{status: :over, total_micro_usd: 15_830_000, fixed_micro_usd: 7_830_000} =
               report.playtest

      under = Costs.report(local, {:ok, playtest_summary(game: 3_000_000)}, @fixed)
      assert %{status: :ok, total_micro_usd: 13_830_000} = under.playtest
    end

    test "configured fixed costs: SEK yearly items convert; threshold 15 USD" do
      domain = Enum.find(Costs.fixed_costs(), &(&1.name =~ "tales-forge.ai"))
      hosting = Enum.find(Costs.fixed_costs(), &(&1.name =~ "Other hosting"))
      rate = Costs.usd_sek().rate

      assert Costs.sek_per_year?(domain)
      assert Costs.sek_per_year(domain) == 2318.75
      assert Costs.fixed_micro_usd(domain) == round(2318.75 / rate / 12 * 1_000_000)
      assert Costs.fixed_micro_usd(domain) == 19_368_432

      assert Costs.sek_per_year?(hosting)
      assert Costs.sek_per_year(hosting) == 400.0
      assert Costs.fixed_micro_usd(hosting) == round(400.0 / rate / 12 * 1_000_000)
      assert Costs.fixed_micro_usd(hosting) == 3_341_185

      fly =
        Enum.find(
          Costs.fixed_costs(),
          &(&1.name =~ "Fly app tales-forge" and not String.contains?(&1.name, "playtest"))
        )

      assert Costs.fixed_micro_usd(fly) == 6_950_000
      refute Costs.sek_per_year?(fly)

      assert Costs.fixed_micro_usd(%{amount: :unknown}) == :unknown
      assert Costs.playtest_warn_usd() == 15.0
    end

    test "report includes SEK yearly items in known totals" do
      local = summary("tales-forge", 0, 15, 30)

      fixed = [
        %{name: "Domain", env: :shared, amount: {:sek_per_year, 2318.75}, source: "a"},
        %{name: "Hosting", env: :shared, amount: {:sek_per_year, 400.0}, source: "b"},
        %{name: "Maybe later", env: :shared, amount: :unknown, source: "c"}
      ]

      report = Costs.report(local, {:error, :not_configured}, fixed)
      assert report.unknown == ["Maybe later"]
      assert report.fixed_known_micro_usd == 19_368_432 + 3_341_185
    end
  end

  describe "SEK conversion" do
    test "uses the configured rate with its date" do
      assert %{rate: rate, as_of: %Date{}, source: source} = Costs.usd_sek()
      assert is_float(rate) and source =~ "Riksbank"
      assert Costs.to_sek(2_000_000, 10.0) == 20.0
      assert_in_delta Costs.to_sek(1_000_000), rate, 1.0e-9
    end
  end

  describe "Peer.fetch/0" do
    test "not configured without the shared token" do
      assert Peer.fetch() == {:error, :not_configured}
      refute Peer.configured?()
      Application.put_env(:ex_tales_forge, :costs_peer, token: " ")
      assert Peer.fetch() == {:error, :not_configured}
    end

    test "playtest's URL comes from the one place, config TalesForge.AppRole" do
      assert Peer.url() == "https://tales-forge-playtest.fly.dev/internal/costs"
      assert Peer.timeout_ms() == 2_000
    end

    test "sends the bearer token and returns the validated summary" do
      Application.put_env(:ex_tales_forge, :costs_peer, token: "t0ken")
      body = playtest_summary(game: 10)

      Req.Test.stub(Peer, fn conn ->
        assert conn.host == "tales-forge-playtest.fly.dev"
        assert conn.request_path == "/internal/costs"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer t0ken"]
        Req.Test.json(conn, body)
      end)

      assert {:ok, %{"app" => "tales-forge-playtest"}} = Peer.fetch()
    end

    test "errors: HTTP status, bad body, unreachable" do
      Application.put_env(:ex_tales_forge, :costs_peer, token: "t0ken")

      Req.Test.stub(Peer, &Plug.Conn.send_resp(&1, 401, "Unauthorized"))
      assert Peer.fetch() == {:error, {:http_status, 401}}

      Req.Test.stub(Peer, &Req.Test.json(&1, %{"hello" => "world"}))
      assert Peer.fetch() == {:error, :bad_response}

      Req.Test.stub(Peer, &Req.Test.transport_error(&1, :timeout))
      assert Peer.fetch() == {:error, :unreachable}
    end
  end

  # A playtest-run summary as served by playtest (15 of 30 days into the month).
  def playtest_summary(opts) do
    zero = %{"calls" => 0, "cost_micro_usd" => 0, "capped" => 0, "errors" => 0}
    line = fn micro -> %{zero | "calls" => 1, "cost_micro_usd" => micro} end
    lines = Map.new(PlaytestRuns.lines(), &{&1, zero})

    month_lines =
      lines
      |> Map.put("gm", line.(Keyword.get(opts, :game, 0)))
      |> Map.put("persona", line.(Keyword.get(opts, :persona, 0)))

    {:ok, summary} =
      PlaytestRuns.normalize(%{
        "app" => "tales-forge-playtest",
        "day_of_month" => 15,
        "days_in_month" => 30,
        "today" => %{"lines" => lines, "outside_runs" => zero},
        "month" => %{
          "lines" => month_lines,
          "outside_runs" => line.(Keyword.get(opts, :outside, 0)),
          "runs" => 2
        }
      })

    summary
  end

  # Production's own summary (Costs.ai_summary shape), all month spend in game.
  # A summary as served by a peer, with all month spend in the game bucket.
  def summary(app, month_micro_usd, day, days) do
    zero = %{"calls" => 0, "cost_micro_usd" => 0, "capped" => 0, "errors" => 0}

    %{
      "app" => app,
      "day_of_month" => day,
      "days_in_month" => days,
      "today" => %{"buckets" => %{"game" => zero, "persona" => zero, "scorer" => zero}},
      "month" => %{
        "total_micro_usd" => month_micro_usd,
        "projected_micro_usd" => Costs.project(month_micro_usd, day, days)
      }
    }
  end

  defp insert!(purpose, micro_usd, inserted_at, opts \\ []) do
    Repo.insert!(%AICall{
      purpose: purpose,
      model: "grok-4.3",
      status: Keyword.get(opts, :status, "ok"),
      latency_ms: 1,
      cost_micro_usd: micro_usd,
      game_session_id: opts[:session] && opts[:session].id,
      inserted_at: inserted_at
    })
  end
end
