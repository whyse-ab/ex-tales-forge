defmodule TalesForgeWeb.AdminLive.LayoutTest do
  use TalesForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

  test "admin pages opt into the themed palette and mark the active tab", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/playtest")

    # .admin-shell switches the paper palette with the theme toggle (app.css).
    assert has_element?(view, "div.admin-shell")
    assert has_element?(view, ~s(#admin-nav a[aria-current="page"]), "Playtest runs")

    refute has_element?(view, ~s(#admin-nav a[aria-current="page"]), "Dashboard")
  end
end
