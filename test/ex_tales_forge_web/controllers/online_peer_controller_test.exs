defmodule TalesForgeWeb.OnlinePeerControllerTest do
  use TalesForgeWeb.ConnCase, async: false

  setup do
    on_exit(fn ->
      Application.delete_env(:ex_tales_forge, :costs_peer)
      Application.delete_env(:ex_tales_forge, :app_name)
    end)

    :ok
  end

  defp get_online(header) do
    build_conn()
    |> then(&if(header, do: put_req_header(&1, "authorization", header), else: &1))
    |> get(~p"/internal/online")
  end

  test "404 on production, locally and while the token is unset" do
    assert get_online("Bearer x").status == 404

    Application.put_env(:ex_tales_forge, :app_name, "tales-forge-playtest")
    assert get_online("Bearer x").status == 404

    Application.put_env(:ex_tales_forge, :costs_peer, token: "right")
    Application.put_env(:ex_tales_forge, :app_name, "tales-forge")
    assert get_online("Bearer right").status == 404
  end

  test "on playtest: 401 without the right token, the list with it" do
    Application.put_env(:ex_tales_forge, :app_name, "tales-forge-playtest")
    Application.put_env(:ex_tales_forge, :costs_peer, token: "right")

    assert get_online(nil).status == 401
    assert get_online("Bearer wrong").status == 401
    assert %{"founders" => list} = json_response(get_online("Bearer right"), 200)
    assert is_list(list)
  end
end
