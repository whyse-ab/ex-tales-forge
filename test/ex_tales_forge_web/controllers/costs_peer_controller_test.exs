defmodule TalesForgeWeb.CostsPeerControllerTest do
  use TalesForgeWeb.ConnCase, async: false

  alias TalesForge.GameSessions
  alias TalesForge.Repo
  alias TalesForge.Schemas.AICall
  alias TalesForge.Schemas.PlaytestRun

  setup do
    on_exit(fn ->
      Application.delete_env(:ex_tales_forge, :costs_peer)
      Application.delete_env(:ex_tales_forge, :app_name)
    end)

    :ok
  end

  defp put_token(token), do: Application.put_env(:ex_tales_forge, :costs_peer, token: token)
  defp put_app(name), do: Application.put_env(:ex_tales_forge, :app_name, name)

  defp get_costs(header) do
    build_conn()
    |> then(&if(header, do: put_req_header(&1, "authorization", header), else: &1))
    |> get(~p"/internal/costs")
  end

  describe "only on the playtest app" do
    test "production and local answer 404, even with the right token" do
      put_token("right-token")

      for app <- ["tales-forge", nil] do
        if app, do: put_app(app), else: Application.delete_env(:ex_tales_forge, :app_name)

        conn = get_costs("Bearer right-token")
        assert conn.status == 404
        refute conn.resp_body =~ "cost"
      end
    end

    test "playtest without COSTS_PEER_TOKEN (unset or blank): 404" do
      put_app("tales-forge-playtest")
      assert get_costs(nil).status == 404
      assert get_costs("Bearer anything").status == 404

      put_token("")
      assert get_costs("Bearer ").status == 404
    end
  end

  describe "auth on playtest" do
    setup do
      put_app("tales-forge-playtest")
      put_token("right-token")
      :ok
    end

    test "401 without a token, or with a malformed or wrong one" do
      assert get_costs(nil).status == 401
      assert get_costs("right-token").status == 401
      assert get_costs("Basic right-token").status == 401
      assert get_costs("Bearer wrong-token").status == 401
      assert get_costs("Bearer right-token-and-more").status == 401

      conn = get_costs("Bearer wrong-token")
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      refute conn.resp_body =~ "cost"
    end

    test "the right token gets playtest-run aggregates only" do
      {:ok, session} = GameSessions.create_session(%{name: "Persona run"})

      Repo.insert!(%PlaytestRun{
        game_session_id: session.id,
        persona: "careful",
        module: "tin_valley",
        turn_limit: 5,
        status: "finished",
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      insert!("gm", 1_234, session.id)
      insert!("persona", 99, session.id)
      insert!("gm", 5_000, nil)

      conn = get_costs("Bearer right-token")
      body = json_response(conn, 200)

      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert body["app"] == "tales-forge-playtest"

      assert body["today"]["lines"]["gm"] == %{
               "calls" => 1,
               "cost_micro_usd" => 1_234,
               "capped" => 0,
               "errors" => 0
             }

      assert body["today"]["lines"]["persona"]["cost_micro_usd"] == 99
      assert body["today"]["game_micro_usd"] == 1_234
      assert body["today"]["outside_runs"]["cost_micro_usd"] == 5_000
      assert body["month"]["runs"] == 1
      refute conn.resp_body =~ "grok-4.3"
      refute conn.resp_body =~ session.id
    end
  end

  defp insert!(purpose, micro_usd, session_id) do
    Repo.insert!(%AICall{
      purpose: purpose,
      model: "grok-4.3",
      status: "ok",
      latency_ms: 1,
      cost_micro_usd: micro_usd,
      game_session_id: session_id
    })
  end
end
