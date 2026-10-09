defmodule TalesForgeWeb.VersionPeerControllerTest do
  use TalesForgeWeb.ConnCase, async: false

  setup do
    on_exit(fn ->
      Application.delete_env(:ex_tales_forge, :costs_peer)
      Application.delete_env(:ex_tales_forge, :app_name)
      System.delete_env("GIT_SHA")
    end)

    :ok
  end

  defp get_version(header) do
    build_conn()
    |> then(&if(header, do: put_req_header(&1, "authorization", header), else: &1))
    |> get(~p"/internal/version")
  end

  test "off (404) while COSTS_PEER_TOKEN is unset or blank" do
    assert get_version(nil).status == 404
    assert get_version("Bearer anything").status == 404

    Application.put_env(:ex_tales_forge, :costs_peer, token: " ")
    assert get_version("Bearer  ").status == 404
  end

  test "401 without the right token" do
    Application.put_env(:ex_tales_forge, :costs_peer, token: "right-token")

    for header <- [nil, "Bearer wrong", "Basic right-token"] do
      conn = get_version(header)
      assert conn.status == 401
      assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      refute conn.resp_body =~ "sha"
    end
  end

  test "with the token, this app's role and running commit, on both apps" do
    Application.put_env(:ex_tales_forge, :costs_peer, token: "right-token")
    System.put_env("GIT_SHA", "702cf6f0000000000000000000000000000000aa")

    for {app, role} <- [{"tales-forge", "production"}, {"tales-forge-playtest", "playtest"}] do
      Application.put_env(:ex_tales_forge, :app_name, app)
      conn = get_version("Bearer right-token")

      assert json_response(conn, 200) == %{
               "app" => role,
               "git_sha" => "702cf6f0000000000000000000000000000000aa"
             }

      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    System.delete_env("GIT_SHA")
    assert %{"git_sha" => nil} = json_response(get_version("Bearer right-token"), 200)
  end
end
