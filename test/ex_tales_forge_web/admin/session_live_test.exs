defmodule TalesForgeWeb.AdminLive.SessionLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.GameSessions
  alias TalesForge.Jido

  setup %{conn: conn} do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    {:ok, conn: log_in_admin(conn)}
  end

  test "dashboard renders", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin")
    assert html =~ "Dashboard"
    assert html =~ "Sessions"
  end

  test "sessions index lists session", %{conn: conn} do
    {:ok, session} = GameSessions.create_session(%{name: "Admin Live Test"})

    {:ok, _view, html} = live(conn, ~p"/admin/sessions")
    assert html =~ "Admin Live Test"
    assert html =~ session.status
  end

  test "session show and delete", %{conn: conn} do
    {:ok, session} = GameSessions.create_session(%{name: "Delete Live Test"})

    {:ok, view, _html} = live(conn, ~p"/admin/sessions/#{session.id}")
    assert render(view) =~ "Delete Live Test"

    render_click(view, "delete")
    assert_redirect(view, ~p"/admin/sessions")
  end
end
