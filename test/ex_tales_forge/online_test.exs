defmodule TalesForge.OnlineTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.Online
  alias TalesForge.Online.Peer

  doctest TalesForge.Online

  setup do
    on_exit(fn ->
      Application.delete_env(:ex_tales_forge, :costs_peer)
      Peer.put([], ~U[2000-01-01 00:00:00Z])
    end)

    :ok
  end

  test "playtest's list counts while fresh, then drops out (TTL)" do
    now = DateTime.utc_now()
    f = %{email: "max@example.com", page: "Playtest runs", app: "playtest", since: now}
    Peer.put([f], now)

    assert Peer.founders(now) == [f]
    assert f in Online.founders()
    assert Peer.founders(DateTime.add(now, Peer.ttl_ms() + 1, :millisecond)) == []
  end

  test "a change in playtest's list is broadcast" do
    Online.subscribe()
    f = %{email: "max@example.com", page: "Docs", app: "playtest", since: DateTime.utc_now()}
    Peer.put([f], DateTime.utc_now())
    assert_receive {:online, :changed}
  end

  test "fetch reads playtest's /internal/online with the shared token" do
    Application.put_env(:ex_tales_forge, :costs_peer, token: "t0k")

    Req.Test.stub(Peer, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer t0k"]
      assert conn.request_path == "/internal/online"

      Req.Test.json(conn, %{
        "founders" => [
          %{
            "email" => "max@example.com",
            "page" => "Docs",
            "app" => "x",
            "since" => "2026-10-10T10:00:00Z"
          }
        ]
      })
    end)

    assert {:ok, [%{email: "max@example.com", app: "playtest", page: "Docs"}]} = Peer.fetch()
  end

  test "fetch: no token, or a bad answer, is an error and never raises" do
    assert Peer.fetch() == {:error, :not_configured}

    Application.put_env(:ex_tales_forge, :costs_peer, token: "t0k")
    Req.Test.stub(Peer, &Plug.Conn.send_resp(&1, 401, "no"))
    assert Peer.fetch() == {:error, {:http_status, 401}}
  end

  test "board API calls are noted per bot" do
    :ok = Online.bot_seen(:gentry)
    assert %DateTime{} = Online.bot_calls()[:gentry]
  end
end
