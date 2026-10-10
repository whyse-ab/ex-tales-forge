defmodule TalesForgeWeb.AdminLive.CostsLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.Costs
  alias TalesForge.Costs.Peer
  alias TalesForge.Costs.PlaytestRuns
  alias TalesForge.GameSessions
  alias TalesForge.Repo
  alias TalesForge.Schemas.AICall
  alias TalesForge.Schemas.PlaytestRun

  setup %{conn: conn} do
    on_exit(fn ->
      Application.delete_env(:ex_tales_forge, :costs_peer)
      Application.delete_env(:ex_tales_forge, :app_name)
    end)

    {:ok, conn: log_in_admin(conn)}
  end

  defp configure_peer, do: Application.put_env(:ex_tales_forge, :costs_peer, token: "t0ken")

  test "admin only" do
    for conn <- [build_conn(), log_in_non_member(build_conn())] do
      assert redirected_to(get(conn, ~p"/admin/operate/costs")) =~ "/admin/login"
    end
  end

  test "in the admin nav, current page marked", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/operate/costs")

    assert has_element?(
             view,
             ~s(#admin-nav a[href="/admin/operate/costs"][aria-current="page"]),
             "Costs"
           )

    {:ok, view, _html} = live(conn, ~p"/admin")
    assert has_element?(view, ~s(#admin-nav a[href="/admin/operate/costs"]), "Costs")
  end

  test "this app's spend by bucket, fixed costs with unknown, SEK and the rate", %{conn: conn} do
    insert!("gm", 2_000_000)
    insert!("intent", 500_000)
    insert!("scorer", 10_000, "error")
    insert!("persona", 0, "capped")

    {:ok, view, html} = live(conn, ~p"/admin/operate/costs")

    %{rate: rate, as_of: as_of} = Costs.usd_sek()
    assert html =~ "1 USD = #{rate} SEK (rate as of #{Date.to_iso8601(as_of)}"

    assert has_element?(view, "#costs-env-local-today-game", "$2.50")
    sek = :erlang.float_to_binary(2.5 * rate, decimals: 2) <> " kr"
    assert has_element?(view, "#costs-env-local-today-game", sek)
    assert has_element?(view, "#costs-env-local-month-scorer", "0 / 1")
    assert has_element?(view, "#costs-env-local-month-persona", "1 / 0")

    assert has_element?(view, "#costs-fixed tr", "Domain tales-forge.ai")
    assert has_element?(view, "#costs-fixed tr", "Other hosting-related costs")
    assert has_element?(view, "#costs-fixed", "2318.75 kr/year")
    assert has_element?(view, "#costs-fixed", "400.00 kr/year")
    assert has_element?(view, "#costs-fixed", "$19.37")
    assert has_element?(view, "#costs-fixed", "$3.34")
    assert has_element?(view, "#costs-fixed", "$6.95")
    refute has_element?(view, "#costs-unknown-note")
  end

  describe "production: playtest read live" do
    test "not configured (no COSTS_PEER_TOKEN): production renders, playtest says so",
         %{conn: conn} do
      insert!("gm", 1_000_000)
      {:ok, view, _html} = live(conn, ~p"/admin/operate/costs")

      assert has_element?(view, "#costs-env-peer", "Playtest: not configured")
      assert has_element?(view, "#costs-env-peer", "COSTS_PEER_TOKEN")
      assert has_element?(view, "#costs-total-playtest-missing", "not configured")
      assert has_element?(view, "#costs-grand-total", "production only")
      assert has_element?(view, "#costs-grand-total", "$1.00")
      assert has_element?(view, "#costs-playtest-unchecked")
    end

    test "playtest down: production numbers render, playtest unavailable", %{conn: conn} do
      configure_peer()
      insert!("gm", 1_000_000)
      Req.Test.stub(Peer, &Req.Test.transport_error(&1, :econnrefused))

      {:ok, view, _html} = live(conn, ~p"/admin/operate/costs")
      render_async(view)

      assert has_element?(view, "#costs-env-peer", "Playtest unavailable")
      assert has_element?(view, "#costs-env-peer", "within 2 s")
      assert has_element?(view, "#costs-total-playtest-missing", "playtest unavailable")
      assert has_element?(view, "#costs-peer-excluded", "playtest unavailable")
      assert has_element?(view, "#costs-env-local-month-game", "$1.00")
      assert has_element?(view, "#costs-grand-total", "production only")
      assert has_element?(view, "#costs-grand-total", "$1.00")
    end

    test "playtest rejects the token: unavailable with the reason", %{conn: conn} do
      configure_peer()
      Req.Test.stub(Peer, &Plug.Conn.send_resp(&1, 401, "Unauthorized"))

      {:ok, view, _html} = live(conn, ~p"/admin/operate/costs")
      render_async(view)

      assert has_element?(view, "#costs-env-peer", "HTTP 401, token rejected")
      assert has_element?(view, "#costs-grand-total", "production only")
    end

    test "playtest up: its section, one grand total and the playtest warning", %{conn: conn} do
      configure_peer()
      insert!("gm", 1_000_000)

      playtest_body =
        playtest_body(%{"gm" => 60_000_000, "persona" => 30_000_000}, 10_000_000)

      Req.Test.stub(Peer, fn conn ->
        assert conn.host == "tales-forge-playtest.fly.dev"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer t0ken"]
        Req.Test.json(conn, playtest_body)
      end)

      {:ok, view, _html} = live(conn, ~p"/admin/operate/costs")
      render_async(view)

      assert has_element?(view, "#costs-env-peer h2", "Playtest (tales-forge-playtest)")
      assert has_element?(view, "#costs-env-peer-month-gm", "$60.00")
      assert has_element?(view, "#costs-env-peer-month-game", "$60.00")
      assert has_element?(view, "#costs-env-peer-month-persona", "$30.00")
      assert has_element?(view, "#costs-env-peer-month-bots", "$30.00")
      assert has_element?(view, "#costs-env-peer-month-total", "$90.00")
      assert has_element?(view, "#costs-env-peer-outside", "$10.00")

      assert has_element?(view, "#costs-total-production", "$1.00")
      assert has_element?(view, "#costs-total-playtest-runs", "$90.00")
      assert has_element?(view, "#costs-total-playtest-runs", "game $60.00, bots $30.00")
      assert has_element?(view, "#costs-total-playtest-outside", "$10.00")
      assert has_element?(view, "#costs-grand-total", "production and playtest")
      assert has_element?(view, "#costs-grand-total", "$101.00")
      sek = :erlang.float_to_binary(101 * Costs.usd_sek().rate, decimals: 2) <> " kr"
      assert has_element?(view, "#costs-grand-total", sek)
      assert has_element?(view, "#costs-playtest-warning", "over the $15.00 threshold")
      refute has_element?(view, "#costs-peer-excluded")
    end

    test "playtest under the threshold: no warning", %{conn: conn} do
      configure_peer()
      Req.Test.stub(Peer, &Req.Test.json(&1, playtest_body(%{}, 0)))

      {:ok, view, _html} = live(conn, ~p"/admin/operate/costs")
      render_async(view)

      assert has_element?(view, "#costs-playtest-ok", "under the $15.00 threshold")
      refute has_element?(view, "#costs-playtest-warning")
    end
  end

  describe "playtest app" do
    setup do
      Application.put_env(:ex_tales_forge, :app_name, "tales-forge-playtest")
      :ok
    end

    test "only playtest-run costs, persona apart from game, manual play on its own line",
         %{conn: conn} do
      configure_peer()
      Req.Test.stub(Peer, fn _conn -> flunk("playtest's page must not fetch production") end)

      {:ok, session} = GameSessions.create_session(%{name: "Persona run"})

      Repo.insert!(%PlaytestRun{
        game_session_id: session.id,
        persona: "careful",
        module: "tin_valley",
        turn_limit: 5,
        status: "finished",
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      insert!("gm", 2_000_000, "ok", session.id)
      insert!("intent_shadow", 10_000, "ok", session.id, "jev")
      insert!("persona", 500_000, "ok", session.id)
      insert!("scorer", 20_000, "ok", session.id, "jev")
      # Manual play on playtest: not a run.
      insert!("gm", 7_000_000)

      {:ok, view, html} = live(conn, ~p"/admin/operate/costs")

      assert has_element?(view, "#costs-runs h2", "Playtest runs (tales-forge-playtest)")
      assert has_element?(view, "#costs-runs-month-gm", "$2.00")
      assert has_element?(view, "#costs-runs-month-jev_intent", "$0.0100")
      assert has_element?(view, "#costs-runs-month-game", "$2.01")
      assert has_element?(view, "#costs-runs-month-persona", "$0.5000")
      assert has_element?(view, "#costs-runs-month-jev_scoring", "$0.0200")
      assert has_element?(view, "#costs-runs-month-bots", "$0.5200")
      assert has_element?(view, "#costs-runs-month-total", "$2.53")
      assert has_element?(view, "#costs-runs-today-total", "$2.53")
      assert has_element?(view, "#costs-runs caption", "runs started: 1")
      sek = :erlang.float_to_binary(2.53 * Costs.usd_sek().rate, decimals: 2) <> " kr"
      assert has_element?(view, "#costs-runs-month-total", sek)

      assert has_element?(view, "#costs-runs-outside", "Not a playtest run")
      assert has_element?(view, "#costs-runs-outside", "$7.00")
      refute html =~ "$9.53"

      # No production section, grand total, fixed costs or call metrics here.
      refute has_element?(view, "#costs-total")
      refute has_element?(view, "#costs-env-peer")
      refute has_element?(view, "#costs-fixed")
      refute has_element?(view, "#costs-call-types")
    end
  end

  test "calls by type: breakdown with persona apart, cache, idle gap and recent sessions",
       %{conn: conn} do
    {:ok, session} =
      TalesForge.GameSessions.create_session(%{name: "Metrics", adventure_id: "tin_valley"})

    now = DateTime.utc_now()

    for {purpose, turn, start_s, cached, cost} <- [
          {"gm", 1, -60, 128, 12_000},
          {"persona", 2, -54, 128, 1_000},
          {"gm", 2, -50, 8_320, 4_000}
        ] do
      started_at = DateTime.add(now, start_s)

      Repo.insert!(%AICall{
        game_session_id: session.id,
        adventure_id: "tin_valley",
        purpose: purpose,
        call_type: "llm",
        conv_id: if(purpose == "gm", do: session.id, else: session.id <> ":persona"),
        model: "grok-4.3",
        status: "ok",
        turn_number: turn,
        started_at: started_at,
        inserted_at: started_at |> DateTime.add(4) |> DateTime.truncate(:second),
        latency_ms: 4_000,
        input_tokens: 9_000,
        cached_tokens: cached,
        cost_micro_usd: cost
      })
    end

    Repo.insert!(%AICall{
      game_session_id: session.id,
      purpose: "turn.prompt",
      call_type: "function",
      model: "elixir",
      status: "ok",
      turn_number: 2,
      latency_ms: 3,
      cost_micro_usd: 0
    })

    {:ok, view, _html} = live(conn, ~p"/admin/operate/costs")

    assert has_element?(view, "#costs-breakdown-game-llm-gm", "$0.0160")
    assert has_element?(view, "#costs-breakdown-game-function-turn_prompt", "3 ms")
    assert has_element?(view, "#costs-breakdown-game-total", "$0.0160")
    assert has_element?(view, "#costs-breakdown-persona-llm-persona", "$0.0010")
    assert has_element?(view, "#costs-cache-gm-later", "1/1 calls hit")
    assert has_element?(view, "#costs-cache-gm", "1/2 calls hit")
    # GM2 started 6 s after GM1 ended (persona on its own conv id in between).
    assert has_element?(view, "#costs-idle-gap", "6.00 s")
    assert has_element?(view, "#costs-session-#{session.id}", "tin_valley")
    assert has_element?(view, "#costs-session-#{session.id}", "1/2 hits")
    # Function rows are not calls in the bucket tables.
    assert has_element?(view, "#costs-env-local-month-game", "2")
  end

  # A playtest-run summary as playtest serves it: month (and today) lines.
  defp playtest_body(month_costs, outside_micro_usd) do
    summary = PlaytestRuns.summary()
    zero = %{"calls" => 0, "cost_micro_usd" => 0, "capped" => 0, "errors" => 0}

    lines =
      Map.new(PlaytestRuns.lines(), fn name ->
        cost = Map.get(month_costs, name, 0)
        {name, %{zero | "calls" => if(cost > 0, do: 1, else: 0), "cost_micro_usd" => cost}}
      end)

    summary
    |> Map.put("app", "tales-forge-playtest")
    |> put_in(["month", "lines"], lines)
    |> put_in(["month", "outside_runs"], %{
      zero
      | "calls" => 1,
        "cost_micro_usd" => outside_micro_usd
    })
  end

  defp insert!(purpose, micro_usd, status \\ "ok", session_id \\ nil, call_type \\ "llm") do
    Repo.insert!(%AICall{
      purpose: purpose,
      call_type: call_type,
      model: "grok-4.3",
      status: status,
      latency_ms: 1,
      cost_micro_usd: micro_usd,
      game_session_id: session_id
    })
  end

  test "the page names its admin section and links back to it", %{conn: conn} do
    {:ok, view, _html} = live(log_in_admin(conn), ~p"/admin/operate/costs")
    assert has_element?(view, ~s(#admin-breadcrumbs a[href="/admin#section-operate"]), "Operate")
    assert has_element?(view, ~s(#admin-breadcrumbs [aria-current="page"]), "Costs")
  end

  describe "admin split: cross links and Jev intent latency" do
    test "production links to playtest's run details and the same page there", %{conn: conn} do
      Application.put_env(:ex_tales_forge, :app_name, "tales-forge")
      {:ok, view, _html} = live(conn, ~p"/admin/operate/costs")

      assert has_element?(
               view,
               ~s(#costs-playtest-details[href="https://tales-forge-playtest.fly.dev/admin/operate/costs"]),
               "Playtest run details on playtest ↗"
             )

      assert has_element?(
               view,
               ~s(#other-app-link[href="https://tales-forge-playtest.fly.dev/admin/operate/costs"])
             )

      refute has_element?(view, "#costs-total-on-production")
    end

    test "playtest links to the total on production", %{conn: conn} do
      Application.put_env(:ex_tales_forge, :app_name, "tales-forge-playtest")
      {:ok, view, _html} = live(conn, ~p"/admin/operate/costs")

      assert has_element?(
               view,
               ~s(#costs-total-on-production[href="https://tales-forge.fly.dev/admin/operate/costs"]),
               "Total and all costs on production ↗"
             )

      assert has_element?(view, "#costs-intent-latency")
    end

    test "Jev intent latency of this app, last 7 days", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/operate/costs")
      assert has_element?(view, "#latency-none", "no Jev intent reads in the last 7 days")

      for ms <- [100, 200, 300, 400] do
        Repo.insert!(%AICall{
          purpose: "intent",
          call_type: "jev",
          model: "jev-1.13.0",
          status: "ok",
          latency_ms: ms,
          cost_micro_usd: 100
        })
      end

      {:ok, view, _html} = live(conn, ~p"/admin/operate/costs")
      assert has_element?(view, "#latency-reads", "4")
      assert has_element?(view, "#latency-max", "400 ms")
      refute has_element?(view, "#latency-none")
    end
  end
end
