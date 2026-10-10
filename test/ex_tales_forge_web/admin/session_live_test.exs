defmodule TalesForgeWeb.AdminLive.SessionLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.Admin
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
    assert html =~ "Admin home"
    assert html =~ "Sessions"
  end

  test "sessions index lists session", %{conn: conn} do
    {:ok, session} = GameSessions.create_session(%{name: "Admin Live Test"})

    {:ok, _view, html} = live(conn, ~p"/admin/play/sessions")
    assert html =~ "Admin Live Test"
    assert html =~ session.status
  end

  test "session show and delete", %{conn: conn} do
    {:ok, session} = GameSessions.create_session(%{name: "Delete Live Test"})

    {:ok, view, _html} = live(conn, ~p"/admin/play/sessions/#{session.id}")
    assert render(view) =~ "Delete Live Test"

    render_click(view, "delete")
    assert_redirect(view, ~p"/admin/play/sessions")
  end

  test "the session form saves name and status to the database", %{conn: conn} do
    {:ok, session} = GameSessions.create_session(%{name: "Form Before"})
    {:ok, view, _html} = live(conn, ~p"/admin/play/sessions/#{session.id}")

    view
    |> form("#session-form", session: %{name: "Form After", status: "paused"})
    |> render_submit()

    assert render(view) =~ "Session updated."
    saved = Admin.get_session!(session.id)
    assert saved.name == "Form After"
    assert saved.status == "paused"
  end

  test "the session form shows validation errors and saves nothing", %{conn: conn} do
    {:ok, session} = GameSessions.create_session(%{name: "Keep Me"})
    {:ok, view, _html} = live(conn, ~p"/admin/play/sessions/#{session.id}")

    html =
      view
      |> form("#session-form", session: %{name: ""})
      |> render_change()

    assert html =~ "can&#39;t be blank"

    view
    |> form("#session-form", session: %{name: ""})
    |> render_submit()

    refute render(view) =~ "Session updated."
    assert Admin.get_session!(session.id).name == "Keep Me"
  end

  test "saving world state keeps the session form in sync", %{conn: conn} do
    {:ok, session} = GameSessions.create_session(%{name: "World Form"})
    {:ok, view, _html} = live(conn, ~p"/admin/play/sessions/#{session.id}")

    view
    |> form("form[phx-submit=save_world_state]", %{world_state_json: ~s({"location_id": "x"})})
    |> render_submit()

    assert render(view) =~ "World state saved."
    assert Admin.get_session!(session.id).world_state == %{"location_id" => "x"}

    view
    |> form("#session-form", session: %{name: "World Form 2"})
    |> render_submit()

    saved = Admin.get_session!(session.id)
    assert saved.name == "World Form 2"
    assert saved.world_state == %{"location_id" => "x"}
  end
end
