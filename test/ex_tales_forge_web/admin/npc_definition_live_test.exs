defmodule TalesForgeWeb.AdminLive.NpcDefinitionLiveTest do
  use TalesForgeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias TalesForge.Admin

  setup %{conn: conn} do
    {:ok, conn: log_in_admin(conn)}
  end

  test "the index lists the pack files", %{conn: conn} do
    [summary | _] = Admin.list_npc_definitions()
    {:ok, view, html} = live(conn, ~p"/admin/npc-definitions")

    assert html =~ "Read-only"
    assert has_element?(view, ~s(a[href="/admin/npc-definitions/#{summary.id}"]))
  end

  test "a definition page is read-only", %{conn: conn} do
    [summary | _] = Admin.list_npc_definitions()
    {:ok, view, html} = live(conn, ~p"/admin/npc-definitions/#{summary.id}")

    assert html =~ "read-only"
    assert has_element?(view, "pre#definition_json", summary.id)
    refute has_element?(view, "form")
    refute has_element?(view, "textarea")
    refute html =~ "Save to disk"
  end

  test "an unknown definition redirects to the index", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/admin/npc-definitions", flash: flash}}} =
             live(conn, ~p"/admin/npc-definitions/no_such_npc")

    assert flash["error"] =~ "No NPC definition"
  end
end
