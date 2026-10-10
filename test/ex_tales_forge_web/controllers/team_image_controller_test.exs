defmodule TalesForgeWeb.TeamImageControllerTest do
  use TalesForgeWeb.ConnCase, async: false

  import TalesForge.ImageFixtures

  alias TalesForge.Chat

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

    {:ok, m} = Chat.post("fredrik@whyse.se", "Look", images: [png()])
    {:ok, image: hd(m.images)}
  end

  test "a signed-in team member gets the image with its stored type", %{
    conn: conn,
    image: image
  } do
    conn = conn |> log_in_admin() |> get(~p"/team/images/#{image.id}")
    assert conn.status == 200
    assert conn.resp_body == png()
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
  end

  test "signed out, the image page goes to the login page", %{conn: conn, image: image} do
    assert redirected_to(get(conn, ~p"/team/images/#{image.id}")) =~ "/admin/login"
  end

  test "an unknown image is 404", %{conn: conn} do
    conn = log_in_admin(conn)
    assert get(conn, ~p"/team/images/#{Ecto.UUID.generate()}").status == 404
    assert get(conn, "/team/images/nope").status == 404
  end

  test "a bot with a board token gets the image; without one, 401", %{conn: conn, image: image} do
    assert get(conn, ~p"/internal/images/#{image.id}").status == 401

    bot = put_req_header(build_conn(), "authorization", "Bearer wrong")
    assert get(bot, ~p"/internal/images/#{image.id}").status == 401

    bot = put_req_header(build_conn(), "authorization", "Bearer case-token")
    conn = get(bot, ~p"/internal/images/#{image.id}")
    assert conn.status == 200
    assert conn.resp_body == png()

    Application.put_env(:ex_tales_forge, :app_name, "tales-forge-playtest")
    assert get(bot, ~p"/internal/images/#{image.id}").status == 404
  end
end
