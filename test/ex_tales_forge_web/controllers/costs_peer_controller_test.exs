defmodule TalesForgeWeb.CostsPeerControllerTest do
  use TalesForgeWeb.ConnCase, async: false

  alias TalesForge.Repo
  alias TalesForge.Schemas.AICall

  setup do
    on_exit(fn -> Application.delete_env(:ex_tales_forge, :costs_peer) end)
    :ok
  end

  defp put_token(token), do: Application.put_env(:ex_tales_forge, :costs_peer, token: token)

  defp get_costs(conn, header) do
    conn
    |> then(&if(header, do: put_req_header(&1, "authorization", header), else: &1))
    |> get(~p"/internal/costs")
  end

  test "disabled (404) when COSTS_PEER_TOKEN is unset or blank", %{conn: conn} do
    assert get_costs(conn, nil).status == 404
    assert get_costs(build_conn(), "Bearer anything").status == 404

    put_token("")
    assert get_costs(build_conn(), "Bearer ").status == 404
  end

  test "401 for a missing, malformed or wrong token", %{conn: conn} do
    put_token("right-token")

    assert get_costs(conn, nil).status == 401
    assert get_costs(build_conn(), "right-token").status == 401
    assert get_costs(build_conn(), "Basic right-token").status == 401
    assert get_costs(build_conn(), "Bearer wrong-token").status == 401
    assert get_costs(build_conn(), "Bearer right-token-and-more").status == 401

    conn = get_costs(build_conn(), "Bearer wrong-token")
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
    refute conn.resp_body =~ "cost"
  end

  test "the right token gets aggregated JSON only", %{conn: conn} do
    put_token("right-token")

    Repo.insert!(%AICall{
      purpose: "gm",
      model: "grok-4.3",
      status: "ok",
      latency_ms: 1,
      cost_micro_usd: 1_234
    })

    conn = get_costs(conn, "Bearer right-token")
    body = json_response(conn, 200)

    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert Map.keys(body) |> Enum.sort() ==
             ~w(app date day_of_month days_in_month generated_at month today)

    assert body["today"]["buckets"]["game"] == %{
             "calls" => 1,
             "cost_micro_usd" => 1_234,
             "capped" => 0,
             "errors" => 0
           }

    assert Map.keys(body["month"]) |> Enum.sort() ==
             ~w(avg_game_micro_usd_per_session buckets game_sessions projected_micro_usd since total_micro_usd)

    refute conn.resp_body =~ "grok-4.3"
  end
end
