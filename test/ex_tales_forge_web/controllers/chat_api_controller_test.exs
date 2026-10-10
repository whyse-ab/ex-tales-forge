defmodule TalesForgeWeb.ChatApiControllerTest do
  use TalesForgeWeb.ConnCase, async: false

  setup do
    Application.put_env(:ex_tales_forge, :board_bots,
      case: [api_token: "case-token"],
      bobby: [],
      gentry: []
    )

    on_exit(fn ->
      Application.delete_env(:ex_tales_forge, :board_bots)
      Application.delete_env(:ex_tales_forge, :app_name)
    end)

    :ok
  end

  defp call(method, token, body \\ nil) do
    conn =
      if token,
        do: put_req_header(build_conn(), "authorization", "Bearer " <> token),
        else: build_conn()

    case method do
      :get -> get(conn, ~p"/internal/chat")
      :post -> post(conn, ~p"/internal/chat", body)
    end
  end

  test "401 without a bot token, 404 on playtest" do
    assert call(:get, nil).status == 401
    assert call(:get, "wrong").status == 401

    Application.put_env(:ex_tales_forge, :app_name, "tales-forge-playtest")
    assert call(:get, "case-token").status == 404
  end

  test "a bot posts and reads messages" do
    assert %{"author" => "bot:case", "body" => "On it."} =
             json_response(call(:post, "case-token", %{"body" => "On it."}), 201)

    assert %{"messages" => [%{"body" => "On it."}]} = json_response(call(:get, "case-token"), 200)
    assert json_response(call(:post, "case-token", %{"body" => " "}), 422)["errors"]
  end
end
