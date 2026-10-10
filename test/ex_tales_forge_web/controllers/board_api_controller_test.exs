defmodule TalesForgeWeb.BoardApiControllerTest do
  use TalesForgeWeb.ConnCase, async: false

  alias TalesForge.BoardApi

  defmodule FakeBoard do
    @moduledoc false
    @behaviour TalesForge.BoardApi

    @impl true
    def handle(action, bot, params),
      do:
        {201,
         %{"action" => Atom.to_string(action), "bot" => Atom.to_string(bot), "id" => params["id"]}}
  end

  setup do
    previous = Application.get_env(:ex_tales_forge, :board_api)
    Application.put_env(:ex_tales_forge, :board_api, FakeBoard)

    Application.put_env(:ex_tales_forge, :board_bots,
      case: [api_token: "case-token"],
      bobby: [api_token: "  "],
      gentry: []
    )

    on_exit(fn ->
      Application.put_env(:ex_tales_forge, :board_api, previous)
      Application.delete_env(:ex_tales_forge, :board_bots)
      Application.delete_env(:ex_tales_forge, :app_name)
    end)

    :ok
  end

  defp call(method, path, token, body \\ %{}) do
    build_conn()
    |> then(&if(token, do: put_req_header(&1, "authorization", "Bearer " <> token), else: &1))
    |> dispatch(@endpoint, method, path, body)
  end

  test "a bot with its token reaches the board module, as itself" do
    conn = call(:post, "/internal/board/ideas/abc/move", "case-token", %{"to" => "check"})
    assert conn.status == 201
    assert json_response(conn, 201) == %{"action" => "move", "bot" => "case", "id" => "abc"}
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    for {method, path, action} <- [
          {:get, "/internal/board/ideas", "index"},
          {:get, "/internal/board/ideas/abc", "show"},
          {:post, "/internal/board/ideas/abc/refinement", "refine"},
          {:post, "/internal/board/ideas/abc/links", "link"},
          {:post, "/internal/board/ideas/abc/comments", "comment"},
          {:post, "/internal/board/prs", "pr"}
        ] do
      assert json_response(call(method, path, "case-token"), 201)["action"] == action
    end
  end

  test "missing, wrong or blank tokens: 401" do
    for token <- [nil, "nope", "  ", ""] do
      assert call(:get, "/internal/board/ideas", token).status == 401
    end
  end

  test "on playtest: 404, even with the right token" do
    Application.put_env(:ex_tales_forge, :app_name, "tales-forge-playtest")
    assert call(:get, "/internal/board/ideas", "case-token").status == 404
  end

  test "board module not deployed: 404" do
    for mod <- [nil, Does.Not.Exist] do
      Application.put_env(:ex_tales_forge, :board_api, mod)
      assert call(:get, "/internal/board/ideas", "case-token").status == 404
      assert BoardApi.impl() == nil
    end
  end

  test "bot_for_token/1 and bot_config/1" do
    assert BoardApi.bot_for_token("case-token") == :case
    assert BoardApi.bot_for_token(nil) == nil
    assert BoardApi.bot_config(:gentry) == []
    assert BoardApi.bots() == [:case, :bobby, :gentry]
  end
end
