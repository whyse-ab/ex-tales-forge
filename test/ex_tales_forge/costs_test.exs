defmodule TalesForge.CostsTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.AICalls
  alias TalesForge.Costs
  alias TalesForge.Costs.Peer
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

  describe "peer summary JSON" do
    test "round-trips through JSON and drops unknown keys" do
      insert!("gm", 42, ~U[2026-10-15 09:00:00Z])
      summary = Costs.ai_summary(@now)

      decoded =
        summary
        |> Map.put("extra", "dropped")
        |> put_in(["month", "buckets", "game", "prompt"], "dropped")
        |> Jason.encode!()
        |> Jason.decode!()

      assert {:ok, ^summary} = Costs.normalize_summary(decoded)
    end

    test "rejects malformed bodies" do
      assert Costs.normalize_summary(%{}) == :error
      assert Costs.normalize_summary(%{"today" => %{}, "month" => %{}}) == :error
      assert Costs.normalize_summary("nope") == :error

      bad = put_in(Costs.ai_summary(@now), ["month", "buckets", "game", "calls"], -1)
      assert Costs.normalize_summary(bad) == :error
    end
  end

  describe "report" do
    @fixed [
      %{name: "App", env: :production, usd: 6.95, source: "a"},
      %{name: "Playtest app", env: :playtest, usd: 3.84, source: "b"},
      %{name: "Playtest db", env: :playtest, usd: 3.99, source: "c"},
      %{name: "Domain", env: :shared, usd: :unknown, source: "d"}
    ]

    test "unknown items are listed and left out of the totals" do
      local = summary("tales-forge", 1_000_000, 15, 30)
      report = Costs.report(local, {:error, :not_configured}, @fixed)

      assert report.unknown == ["Domain"]
      assert report.fixed_known_micro_usd == 14_780_000
      assert report.ai_month_micro_usd == 1_000_000
      assert report.total_so_far_micro_usd == 15_780_000
      assert report.ai_projected_micro_usd == 2_000_000
      assert report.total_projected_micro_usd == 16_780_000
      refute report.peer_included
      assert report.playtest.status == :unavailable
    end

    test "both environments add up; playtest fixed + projected AI against the threshold" do
      local = summary("tales-forge", 1_000_000, 15, 30)
      peer = summary("tales-forge-playtest", 4_000_000, 15, 30)

      report = Costs.report(local, {:ok, peer}, @fixed)
      assert report.peer_included
      assert report.ai_month_micro_usd == 5_000_000
      assert report.ai_projected_micro_usd == 10_000_000

      # 3.84 + 3.99 + 8.00 projected = 15.83 > 15
      assert %{status: :over, total_micro_usd: 15_830_000, fixed_micro_usd: 7_830_000} =
               report.playtest

      under =
        Costs.report(local, {:ok, summary("tales-forge-playtest", 3_000_000, 15, 30)}, @fixed)

      assert %{status: :ok, total_micro_usd: 13_830_000} = under.playtest
    end

    test "on the playtest app, its own numbers drive the warning" do
      Application.put_env(:ex_tales_forge, :app_name, "tales-forge-playtest")
      insert!("gm", 4_000_000, ~U[2026-10-02 10:00:00Z])

      local = Costs.ai_summary(@now)
      assert local["app"] == "tales-forge-playtest"
      assert Costs.peer_label() == "production"
      assert Costs.report(local, {:error, :unreachable}, @fixed).playtest.status == :over
    end

    test "configured fixed costs: domain unknown, threshold 15 USD" do
      domain = Enum.find(Costs.fixed_costs(), &(&1.name =~ "tales-forge.ai"))
      assert Costs.fixed_micro_usd(domain) == :unknown
      assert Costs.playtest_warn_usd() == 15.0
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
    test "not configured without both URL and token" do
      assert Peer.fetch() == {:error, :not_configured}
      Application.put_env(:ex_tales_forge, :costs_peer, url: "http://peer.test", token: " ")
      assert Peer.fetch() == {:error, :not_configured}
    end

    test "sends the bearer token and returns the validated summary" do
      Application.put_env(:ex_tales_forge, :costs_peer, url: "http://peer.test/", token: "t0ken")
      body = summary("tales-forge-playtest", 10, 1, 31)

      Req.Test.stub(Peer, fn conn ->
        assert conn.request_path == "/internal/costs"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer t0ken"]
        Req.Test.json(conn, body)
      end)

      assert {:ok, %{"app" => "tales-forge-playtest"}} = Peer.fetch()
    end

    test "errors: HTTP status, bad body, unreachable" do
      Application.put_env(:ex_tales_forge, :costs_peer, url: "http://peer.test", token: "t0ken")

      Req.Test.stub(Peer, &Plug.Conn.send_resp(&1, 401, "Unauthorized"))
      assert Peer.fetch() == {:error, {:http_status, 401}}

      Req.Test.stub(Peer, &Req.Test.json(&1, %{"hello" => "world"}))
      assert Peer.fetch() == {:error, :bad_response}

      Req.Test.stub(Peer, &Req.Test.transport_error(&1, :timeout))
      assert Peer.fetch() == {:error, :unreachable}
    end
  end

  # A summary as served by a peer, with all month spend in the game bucket.
  def summary(app, month_micro_usd, day, days) do
    zero = %{"calls" => 0, "cost_micro_usd" => 0, "capped" => 0, "errors" => 0}
    buckets = %{"game" => zero, "persona" => zero, "scorer" => zero}

    month_buckets =
      put_in(buckets, ["game"], %{zero | "calls" => 3, "cost_micro_usd" => month_micro_usd})

    {:ok, summary} =
      Costs.normalize_summary(%{
        "app" => app,
        "day_of_month" => day,
        "days_in_month" => days,
        "today" => %{"buckets" => buckets},
        "month" => %{"buckets" => month_buckets, "game_sessions" => 1}
      })

    summary
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
