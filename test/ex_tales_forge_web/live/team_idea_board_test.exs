defmodule TalesForgeWeb.TeamIdeaBoardTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.Board

  doctest TalesForgeWeb.TeamIdeaBoard

  setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

  defp open(view, idea), do: view |> element("#tile-#{idea.id} button") |> render_click()

  test "layout: areas, sizes, avatars; the placeholder is gone", %{conn: conn} do
    {:ok, a} = Board.create_idea("bo@example.com", %{"title" => "Backlog one"})

    {:ok, b} =
      Board.create_idea("bo@example.com", %{
        "title" => "Active one",
        "body" => String.duplicate("long task ", 40)
      })

    {:ok, _} = Board.move(b, {:founder, "bo@example.com"}, "refining")
    {:ok, view, _} = live(conn, "/team")

    refute has_element?(view, "#board-soon")

    for col <- ~w(ideas refining check building done parked),
        do: assert(has_element?(view, "#board-col-#{col}"))

    assert has_element?(view, ~s(#board-col-ideas #tile-#{a.id}[data-size="thin"]))

    assert has_element?(
             view,
             ~s(#board-col-refining #tile-#{b.id}[data-size="small"] [data-role="task"])
           )

    refute has_element?(view, ~s(#tile-#{a.id} [data-role="task"]))
    assert has_element?(view, ~s(#tile-#{a.id} svg[aria-hidden="true"][data-avatar]))
    refute has_element?(view, "#board-modal")
  end

  test "add, open in a dialog, vote and take back, close", %{conn: conn} do
    {:ok, view, _} = live(conn, "/team")

    view
    |> form("#board-add", idea: %{title: "Brenna remembers regulars", body: "By name."})
    |> render_submit()

    [idea] = Board.board()["ideas"]

    open(view, idea)
    assert has_element?(view, ~s(#board-modal [role="dialog"][aria-modal="true"]))
    assert has_element?(view, "#board-modal-title", "Brenna remembers regulars")

    view |> element("#card-#{idea.id} button[phx-value-value='1']") |> render_click()
    assert has_element?(view, ~s(#card-#{idea.id} button[aria-pressed="true"]), "+1")
    view |> element("#card-#{idea.id} button[phx-value-value='1']") |> render_click()
    refute has_element?(view, ~s(#card-#{idea.id} button[aria-pressed="true"]))

    view |> element("#board-modal-close") |> render_click()
    refute has_element?(view, "#board-modal")
  end

  test "Move to, refinement, the open -1 block, drag, comments and links", %{conn: conn} do
    {:ok, idea} = Board.create_idea("bo@example.com", %{"title" => "Fishing"})
    {:ok, view, _} = live(conn, "/team")
    open(view, idea)

    view |> form("#card-#{idea.id}-move", %{to: "refining"}) |> render_submit()
    assert has_element?(view, "#board-col-refining #tile-#{idea.id}")

    view
    |> form("#card-#{idea.id}-refine", %{
      details: "Rods.",
      open_questions: "Where?\nBait?",
      rough_cost: "M",
      verdict: "feasible"
    })
    |> render_submit()

    assert render(view) =~ "Where? · Bait?"
    {:ok, idea} = Board.move(Board.get_idea!(idea.id), {:bot, :case}, "check")
    {:ok, _} = Board.vote(idea, "bo@example.com", -1)
    send(view.pid, {:board, :changed})
    assert has_element?(view, "#card-#{idea.id}-blocked")
    assert has_element?(view, "#tile-#{idea.id}", "−1")

    view |> form("#card-#{idea.id}-move", %{to: "building"}) |> render_submit()
    assert has_element?(view, "#card-#{idea.id}-error", "voted -1")
    assert has_element?(view, "#board-col-check #tile-#{idea.id}")

    view
    |> with_target("#idea-board-live")
    |> render_hook("move", %{"card_id" => idea.id, "to" => "refining"})

    assert has_element?(view, "#board-col-refining #tile-#{idea.id}")

    view |> form("#card-#{idea.id}-comment", %{body: "Looks fun"}) |> render_submit()
    assert render(view) =~ "Looks fun"

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
