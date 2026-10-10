defmodule TalesForgeWeb.TeamIdeaBoardTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.Board

  setup %{conn: conn} do
    conn = log_in_admin(conn)
    {:ok, conn: conn, me: TalesForge.AdminAuth.current_email(conn) || "admin@example.com"}
  end

  defp card(view, title), do: view |> element("article", title) |> render()

  test "the board replaces the placeholder; add, vote, take back", %{conn: conn} do
    {:ok, view, _} = live(conn, "/team")
    assert has_element?(view, "#idea-board-live")
    refute has_element?(view, "#board-soon")

    for col <- ~w(ideas refining check building done parked),
        do: assert(has_element?(view, "#board-col-#{col}"))

    view
    |> form("#board-add", idea: %{title: "Brenna remembers regulars", body: "By name."})
    |> render_submit()

    assert has_element?(view, "#board-col-ideas article", "Brenna remembers regulars")
    [idea] = Board.board()["ideas"]

    view |> element("#card-#{idea.id} button[phx-value-value='1']") |> render_click()
    assert has_element?(view, ~s(#card-#{idea.id} button[aria-pressed="true"]), "+1")
    view |> element("#card-#{idea.id} button[phx-value-value='1']") |> render_click()
    refute has_element?(view, ~s(#card-#{idea.id} button[aria-pressed="true"]))
    assert card(view, "Brenna") =~ "Vote +1"
  end

  test "keyboard move, refinement, the open -1 block, comments and links", %{conn: conn} do
    {:ok, idea} = Board.create_idea("bo@example.com", %{"title" => "Fishing"})
    {:ok, view, _} = live(conn, "/team")

    view |> form("#card-#{idea.id}-move", %{to: "refining"}) |> render_submit()
    assert has_element?(view, "#board-col-refining #card-#{idea.id}")

    view
    |> form("#card-#{idea.id}-refine", %{
      details: "Rods.",
      open_questions: "Where?\nBait?",
      rough_cost: "M",
      verdict: "feasible"
    })
    |> render_submit()

    assert card(view, "Fishing") =~ "Where? · Bait?"
    {:ok, idea} = Board.move(Board.get_idea!(idea.id), {:bot, :case}, "check")
    {:ok, _} = Board.vote(idea, "bo@example.com", -1)
    render(view)
    send(view.pid, {:board, :changed})
    assert has_element?(view, "#card-#{idea.id}-blocked")

    view |> form("#card-#{idea.id}-move", %{to: "building"}) |> render_submit()
    assert has_element?(view, "#card-#{idea.id}-error", "voted -1")
    assert has_element?(view, "#board-col-check #card-#{idea.id}")

    # Drag and drop sends the same event.
    view
    |> with_target("#idea-board-live")
    |> render_hook("move", %{"card_id" => idea.id, "to" => "refining"})

    assert has_element?(view, "#board-col-refining #card-#{idea.id}")

    view |> form("#card-#{idea.id}-comment", %{body: "Looks fun"}) |> render_submit()
    assert card(view, "Fishing") =~ "Looks fun"

    view
    |> form("#card-#{idea.id}-link", %{kind: "doc", url: "https://example.com/d"})
    |> render_submit()

    assert has_element?(view, ~s(#card-#{idea.id} a[href="https://example.com/d"]))
  end

  test "on playtest the placeholder stays", %{conn: conn} do
    Application.put_env(:ex_tales_forge, :app_name, "tales-forge-playtest")
    on_exit(fn -> Application.delete_env(:ex_tales_forge, :app_name) end)
    {:ok, view, _} = live(conn, "/team")
    assert has_element?(view, "#board-soon")
    refute has_element?(view, "#idea-board-live")
  end
end
