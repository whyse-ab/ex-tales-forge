defmodule TalesForgeWeb.AdminLive.CostsLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.Costs
  alias TalesForge.Costs.Peer
  alias TalesForge.Repo
  alias TalesForge.Schemas.AICall

  setup %{conn: conn} do
    on_exit(fn ->
      Application.delete_env(:ex_tales_forge, :costs_peer)
      Application.delete_env(:ex_tales_forge, :app_name)
    end)

    {:ok, conn: log_in_admin(conn)}
  end

  defp configure_peer,
    do:
      Application.put_env(:ex_tales_forge, :costs_peer,
        url: "http://playtest.test",
        token: "t0ken"
      )

  test "admin only" do
    for conn <- [build_conn(), log_in_admin(build_conn(), "stranger@example.com")] do
      assert redirected_to(get(conn, ~p"/admin/costs")) =~ "/admin/login"
    end
  end

  test "in the admin nav, current page marked", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/costs")
    assert has_element?(view, ~s(#admin-nav a[href="/admin/costs"][aria-current="page"]), "Costs")

    {:ok, view, _html} = live(conn, ~p"/admin")
    assert has_element?(view, ~s(#admin-nav a[href="/admin/costs"]), "Costs")
  end

  test "this app's spend by bucket, fixed costs with unknown, SEK and the rate", %{conn: conn} do
    insert!("gm", 2_000_000)
    insert!("intent", 500_000)
    insert!("scorer", 10_000, "error")
    insert!("persona", 0, "capped")

    {:ok, view, html} = live(conn, ~p"/admin/costs")

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

  test "peer not configured: page renders and says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/costs")

    assert has_element?(view, "#costs-env-peer", "Playtest: not configured")
    assert has_element?(view, "#costs-peer-excluded", "not configured")
    assert has_element?(view, "#costs-playtest-unchecked")
    assert has_element?(view, "#costs-total", "this app only")
  end

  test "peer down: page still renders, playtest unavailable", %{conn: conn} do
    configure_peer()
    Req.Test.stub(Peer, &Req.Test.transport_error(&1, :econnrefused))

    {:ok, view, _html} = live(conn, ~p"/admin/costs")
    render_async(view)

    assert has_element?(view, "#costs-env-peer", "Playtest unavailable")
    assert has_element?(view, "#costs-peer-excluded", "unavailable")
    assert has_element?(view, "#costs-env-local")
    assert has_element?(view, "#costs-total", "this app only")
  end

  test "peer rejects the token: unavailable with the reason", %{conn: conn} do
    configure_peer()
    Req.Test.stub(Peer, &Plug.Conn.send_resp(&1, 401, "Unauthorized"))

    {:ok, view, _html} = live(conn, ~p"/admin/costs")
    render_async(view)

    assert has_element?(view, "#costs-env-peer", "HTTP 401")
  end

  test "peer up: both environments, totals and the playtest warning", %{conn: conn} do
    configure_peer()
    insert!("gm", 1_000_000)

    peer_body =
      Costs.ai_summary()
      |> Map.put("app", "tales-forge-playtest")
      |> put_in(["month", "buckets", "game", "cost_micro_usd"], 100_000_000)
      |> put_in(["month", "buckets", "game", "calls"], 7)

    Req.Test.stub(Peer, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer t0ken"]
      Req.Test.json(conn, peer_body)
    end)

    {:ok, view, _html} = live(conn, ~p"/admin/costs")
    render_async(view)

    assert has_element?(view, "#costs-env-peer h2", "Playtest (tales-forge-playtest)")
    assert has_element?(view, "#costs-env-peer-month-game", "$100.00")
    assert has_element?(view, "#costs-total", "both environments")
    assert has_element?(view, "#costs-total", "$101.00")
    assert has_element?(view, "#costs-playtest-warning", "over the $15.00 threshold")
    refute has_element?(view, "#costs-peer-excluded")
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

    {:ok, view, _html} = live(conn, ~p"/admin/costs")

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

  test "playtest under the threshold: no warning", %{conn: conn} do
    configure_peer()

    peer_body = Map.put(Costs.ai_summary(), "app", "tales-forge-playtest")
    Req.Test.stub(Peer, &Req.Test.json(&1, peer_body))

    {:ok, view, _html} = live(conn, ~p"/admin/costs")
    render_async(view)

    assert has_element?(view, "#costs-playtest-ok", "under the $15.00 threshold")
    refute has_element?(view, "#costs-playtest-warning")
  end

  defp insert!(purpose, micro_usd, status \\ "ok") do
    Repo.insert!(%AICall{
      purpose: purpose,
      model: "grok-4.3",
      status: status,
      latency_ms: 1,
      cost_micro_usd: micro_usd
    })
  end
end
