defmodule TalesForgeWeb.AdminLive.NpcLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.Admin
  alias TalesForge.GameSessions
  alias TalesForge.Jido

  setup %{conn: conn} do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    {:ok, session} = GameSessions.create_session(%{name: "NPC Live Test"})
    [npc | _] = Admin.list_npc_instances(session.id)

    {:ok, conn: log_in_admin(conn), session: session, npc: npc}
  end

  test "index links to an NPC page that renders it", %{conn: conn, session: session, npc: npc} do
    {:ok, index, _html} = live(conn, ~p"/admin/play/sessions/#{session.id}/npcs")
    path = ~p"/admin/play/sessions/#{session.id}/npcs/#{npc.npc_id}"
    assert has_element?(index, ~s(a[href="#{path}"]))

    {:ok, view, html} = live(conn, path)
    assert html =~ npc.npc_id
    assert has_element?(view, "#npc-form")
    assert has_element?(view, "textarea#runtime_json")
  end

  test "saving runtime state keeps the page working", %{conn: conn, session: session, npc: npc} do
    {:ok, view, _html} = live(conn, ~p"/admin/play/sessions/#{session.id}/npcs/#{npc.npc_id}")

    view
    |> form("form[phx-submit=save_runtime]", %{runtime_json: ~s({"mood": "wary"})})
    |> render_submit()

    assert render(view) =~ "Runtime state saved."
    assert Admin.get_npc_instance!(session.id, npc.npc_id).runtime_state == %{"mood" => "wary"}
  end

  test "an NPC from another session redirects instead of crashing", %{conn: conn, npc: npc} do
    {:ok, other} = GameSessions.create_session(%{name: "Other session"})
    # Make sure the other session really has no NPC with this slug.
    for n <- Admin.list_npc_instances(other.id), n.npc_id == npc.npc_id do
      TalesForge.Repo.delete!(n)
    end

    assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
             live(conn, ~p"/admin/play/sessions/#{other.id}/npcs/#{npc.npc_id}")

    assert to == ~p"/admin/play/sessions/#{other.id}/npcs"
    assert flash["error"] =~ "No NPC"
  end

  test "an unknown NPC slug redirects instead of crashing", %{conn: conn, session: session} do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, ~p"/admin/play/sessions/#{session.id}/npcs/no_such_npc")

    assert to == ~p"/admin/play/sessions/#{session.id}/npcs"
  end

  test "the disposition form saves to the database", %{conn: conn, session: session, npc: npc} do
    {:ok, view, _html} = live(conn, ~p"/admin/play/sessions/#{session.id}/npcs/#{npc.npc_id}")

    view
    |> form("#npc-form", npc: %{disposition: "0.7"})
    |> render_submit()

    assert render(view) =~ "Disposition updated."
    assert Admin.get_npc_instance!(session.id, npc.npc_id).disposition == 0.7
  end

  test "the disposition form shows validation errors and saves nothing",
       %{conn: conn, session: session, npc: npc} do
    {:ok, view, _html} = live(conn, ~p"/admin/play/sessions/#{session.id}/npcs/#{npc.npc_id}")

    html =
      view
      |> form("#npc-form", npc: %{disposition: "lots"})
      |> render_change()

    assert html =~ "is invalid"

    view
    |> form("#npc-form", npc: %{disposition: "lots"})
    |> render_submit()

    refute render(view) =~ "Disposition updated."
    assert Admin.get_npc_instance!(session.id, npc.npc_id).disposition == npc.disposition
  end
end
