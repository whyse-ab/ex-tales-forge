defmodule TalesForgeWeb.AccessControlTest do
  @moduledoc """
  The whole app is behind GitHub team sign-in. Logged out, every route except
  the short public list below redirects to the login page, and no LiveView can
  be mounted (so nothing can start an AI call).
  """

  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Phoenix.LiveView.Socket
  alias TalesForge.GameSessions
  alias TalesForge.Repo
  alias TalesForgeWeb.AdminLive.Hooks

  # {verb, path} of every route anyone may call signed out. Adding a route here
  # needs a reason; everything else must require a team member.
  @public [
    {:get, "/health"},
    {:get, "/admin/login"},
    {:get, "/admin/auth/github"},
    {:get, "/admin/auth/github/callback"},
    {:delete, "/admin/logout"},
    # Machine-to-machine, bearer token (COSTS_PEER_TOKEN); see CostsPeerController.
    {:get, "/internal/costs"}
  ]

  @id Ecto.UUID.generate()

  defp concrete(path), do: String.replace(path, ~r/:[a-z_]+|\*[a-z_]+/, @id)

  describe "logged out" do
    test "representative pages redirect to the login page" do
      for path <- [
            "/",
            "/new/tin_valley",
            "/play/#{@id}",
            "/team",
            "/admin",
            "/admin/costs",
            "/admin/playtest",
            "/admin/sessions",
            "/admin/oban",
            "/admin/code-docs",
            "/admin/code-docs/index.html"
          ] do
        conn = get(build_conn(), path)
        assert redirected_to(conn) == "/admin/login", "#{path} is reachable logged out"
      end
    end

    # Covers routes added later (e.g. character creation) without listing them.
    test "every route in the router outside the public list redirects to login" do
      routes =
        TalesForgeWeb.Router
        |> Phoenix.Router.routes()
        |> Enum.reject(&({&1.verb, &1.path} in @public))

      assert length(routes) > 15

      for %{verb: verb, path: path} <- routes do
        conn = dispatch(build_conn(), @endpoint, verb, concrete(path), %{})

        assert redirected_to(conn) == "/admin/login",
               "#{verb |> to_string() |> String.upcase()} #{path} is reachable logged out"
      end
    end

    test "the public list is exactly what the router exposes" do
      routes = TalesForgeWeb.Router |> Phoenix.Router.routes() |> Enum.map(&{&1.verb, &1.path})
      for route <- @public, do: assert(route in routes)
    end

    test "LiveViews (game, character play, admin) can't be mounted" do
      for path <- ["/", "/new/tin_valley", "/play/#{@id}", "/team", "/admin", "/admin/costs"] do
        assert {:error, {:redirect, %{to: "/admin/login"}}} = live(build_conn(), path)
      end
    end

    # A websocket mount doesn't go through the router plugs: the LiveViews
    # themselves (and the live_session hooks) must refuse.
    test "a LiveView mounted without the router plugs still refuses" do
      for view <- [TalesForgeWeb.HomeLive, TalesForgeWeb.AdminLive.CostsLive] do
        assert {:error, {:redirect, %{to: "/admin/login"}}} =
                 live_isolated(build_conn(), view, session: %{})
      end

      socket = %Socket{endpoint: @endpoint}

      assert {:halt, %Socket{redirected: {:redirect, %{to: "/admin/login"}}}} =
               Hooks.on_mount(:require_team_member, %{}, %{}, socket)

      assert {:halt, _} = TalesForgeWeb.LiveAuth.on_mount(:default, %{}, %{}, socket)
    end

    test "opening a game doesn't queue its opening scene (no AI call)" do
      Oban.Testing.with_testing_mode(:manual, fn ->
        {:ok, session} = GameSessions.create_session(%{name: "Gate", adventure_id: "tin_valley"})
        jobs_before = Repo.aggregate(Oban.Job, :count)

        assert build_conn() |> get(~p"/play/#{session.id}") |> redirected_to() == "/admin/login"
        assert {:error, {:redirect, _}} = live(build_conn(), ~p"/play/#{session.id}")

        assert Repo.aggregate(Oban.Job, :count) == jobs_before
      end)
    end

    test "the login page and its assets render" do
      html = build_conn() |> get(~p"/admin/login") |> html_response(200)
      assert html =~ "Sign in"

      for asset <- ["/favicon.ico", "/robots.txt"] do
        assert build_conn() |> get(asset) |> response(200)
      end
    end
  end

  test "the Fly health check answers 200 logged out, without a session cookie" do
    conn = get(build_conn(), ~p"/health")

    assert response(conn, 200) == "ok"
    refute Map.has_key?(conn.resp_cookies, "_ex_tales_forge_key")
  end

  test "fly.toml and fly.playtest.toml point the health check at /health" do
    for file <- ["fly.toml", "fly.playtest.toml"] do
      assert File.read!(file) =~ ~s(path = "/health"), "#{file} health check path"
    end
  end

  describe "magic-link sign-in is gone" do
    test "its routes answer 404" do
      conn = post(build_conn(), "/admin/login", %{"email" => "founder@example.com"})
      assert response(conn, 404)
      assert build_conn() |> get("/admin/magic/some-token") |> response(404)
    end
  end

  describe "a signed-in GitHub user who isn't on the team" do
    test "is refused everywhere" do
      conn = log_in_non_member(build_conn())

      for path <- ["/", "/play/#{@id}", "/admin", "/admin/code-docs/"] do
        assert conn |> get(path) |> redirected_to() == "/admin/login"
      end

      assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn, "/")
    end
  end

  describe "a team member" do
    setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

    test "gets the player and admin pages with no second admin step", %{conn: conn} do
      assert conn |> get("/") |> html_response(200)
      assert conn |> get("/admin") |> html_response(200)
      assert conn |> get("/admin/costs") |> html_response(200)
      assert {:ok, _view, _html} = live(conn, "/admin/oban/home")
    end
  end
end
