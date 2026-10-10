defmodule TalesForgeWeb.TeamIdeaBoardTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.Board

  doctest TalesForgeWeb.TeamIdeaBoard

  setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

  defp open(view, idea),
    do: view |> element("#tile-#{idea.id} button[aria-haspopup]") |> render_click()

  test "layout: areas, sizes, avatars; the placeholder is gone", %{conn: conn} do
    {:ok, a} = Board.create_idea("bo@example.com", %{"title" => "Backlog one"})

    {:ok, b} =
      Board.create_idea("bo@example.com", %{
        "title" => "Active one",
        "body" => String.duplicate("long task ", 40)
      })

    {:ok, b} = Board.vote(b, "bo@example.com", 1)
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

    view |> element("#card-#{idea.id} button[phx-value-vote='1']") |> render_click()
    assert has_element?(view, ~s(#card-#{idea.id} button[aria-pressed="true"]), "+1")
    view |> element("#card-#{idea.id} button[phx-value-vote='1']") |> render_click()
    refute has_element?(view, ~s(#card-#{idea.id} button[aria-pressed="true"]))

    view |> element("#board-modal-close") |> render_click()
    refute has_element?(view, "#board-modal")
  end

  test "Move to, refinement, comment gates, drag, comments and links", %{conn: conn} do
    {:ok, idea} = Board.create_idea("bo@example.com", %{"title" => "Fishing"})
    {:ok, idea} = Board.vote(idea, "bo@example.com", 1)
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
    {:ok, _} = Board.move(Board.get_idea!(idea.id), {:bot, :case}, "check")
    send(view.pid, {:board, :changed})

    view |> form("#card-#{idea.id}-move", %{to: "building"}) |> render_submit()
    assert has_element?(view, "#card-#{idea.id}-error", "Answer or defer the 2 open questions")
    assert has_element?(view, "#board-col-check #tile-#{idea.id}")

    # A drag that needs a comment opens the card with the reason.
    view
    |> with_target("#idea-board-live")
    |> render_hook("move", %{"card_id" => idea.id, "to" => "refining"})

    assert has_element?(
             view,
             "#card-#{idea.id}-error",
             "Write a comment that says what to change."
           )

    view
    |> form("#card-#{idea.id}-move", %{to: "refining", note: "Cheaper, please."})
    |> render_submit()

    assert has_element?(view, "#board-col-refining #tile-#{idea.id}")

    view |> form("#card-#{idea.id}-comment", %{body: "Looks fun"}) |> render_submit()
    assert render(view) =~ "Looks fun"

    view
    |> form("#card-#{idea.id}-link", %{kind: "doc", url: "https://example.com/d"})
    |> render_submit()

    assert has_element?(view, ~s(#card-#{idea.id} a[href="https://example.com/d"]))
  end

  describe "card states (design-board-states.md)" do
    test "vote gates and reasons: no vote, a downvote, then an upvote opens Refining", %{
      conn: conn
    } do
      {:ok, idea} = Board.create_idea("bo@example.com", %{"title" => "Fishing"})
      {:ok, view, _} = live(conn, "/team")

      assert has_element?(view, ~s(#tile-#{idea.id}[data-faded="true"].opacity-50))
      assert has_element?(view, "#tile-#{idea.id}-reason", "Needs an upvote.")
      assert has_element?(view, ~s(#tile-#{idea.id}[data-moves="parked"]))

      open(view, idea)

      assert has_element?(
               view,
               "#card-#{idea.id}-move option[value=refining][disabled]",
               "Needs an upvote."
             )

      assert has_element?(
               view,
               "#card-#{idea.id}-closed-moves",
               "Refining (Case): Needs an upvote."
             )

      view
      |> with_target("#idea-board-live")
      |> render_hook("move", %{"card_id" => idea.id, "to" => "refining"})

      assert has_element?(view, "#card-#{idea.id}-error", "Needs an upvote.")
      assert has_element?(view, "#board-col-ideas #tile-#{idea.id}")

      view |> element("#tile-#{idea.id}-down") |> render_click()
      assert has_element?(view, ~s(#tile-#{idea.id}[data-needs-work="true"] .border-warning))
      assert has_element?(view, "#tile-#{idea.id} .badge-warning", "Needs work")
      assert has_element?(view, "#tile-#{idea.id}-reason", "Has a downvote.")
      refute has_element?(view, ~s(#tile-#{idea.id}[data-faded="true"]))

      view |> element("#tile-#{idea.id}-up") |> render_click()
      refute has_element?(view, ~s(#tile-#{idea.id}[data-needs-work="true"]))
      refute has_element?(view, "#tile-#{idea.id}-reason")
      assert has_element?(view, ~s(#tile-#{idea.id}[data-moves="refining parked"]))

      open(view, idea)
      view |> form("#card-#{idea.id}-move", %{to: "refining"}) |> render_submit()
      assert has_element?(view, "#board-col-refining #tile-#{idea.id}")
      assert has_element?(view, "#tile-#{idea.id}-reason", "Waits for Case's refinement")
    end

    test "the backlog is sorted by net votes, then total votes", %{conn: conn} do
      ids =
        for {title, votes} <- [
              {"None", []},
              {"Two up", [1, 1]},
              {"Two up one down", [1, 1, -1, 1]},
              {"One up", [1]}
            ] do
          {:ok, idea} = Board.create_idea("bo@example.com", %{"title" => title})

          for {v, n} <- Enum.with_index(votes),
              do: {:ok, _} = Board.vote(idea, "f#{n}@x", v)

          {title, idea.id}
        end
        |> Map.new()

      {:ok, view, _} = live(conn, "/team")
      html = view |> element("#board-col-ideas") |> render()

      order =
        ~r/id="tile-([0-9a-f-]{36})"/
        |> Regex.scan(html)
        |> Enum.map(fn [_, id] -> Enum.find_value(ids, fn {t, i} -> i == id && t end) end)

      # "Two up one down": net 2, 4 votes; "Two up": net 2, 2 votes.
      assert order == ["Two up one down", "Two up", "One up", "None"]
    end
  end

  describe "voting (Fredrik's report 2026-10-10: the browser sends the button's empty value)" do
    # A browser merges a <button>'s own `value` ("") into the click payload;
    # LiveViewTest doesn't, so every click here sends it explicitly.
    @browser %{"value" => ""}

    defp click(view, selector), do: view |> element(selector) |> render_click(@browser)

    defp net(view, id),
      do:
        view
        |> element("#tile-#{id}-net")
        |> render()
        |> then(&Regex.run(~r/>(-?\d+)</, &1))
        |> List.last()

    setup do
      {:ok, thin} = Board.create_idea("bo@example.com", %{"title" => "Thin one"})
      {:ok, small} = Board.create_idea("bo@example.com", %{"title" => "Small one"})
      {:ok, small} = Board.vote(small, "ada@example.com", 1)
      {:ok, small} = Board.move(small, {:founder, "bo@example.com"}, "refining")
      {:ok, small} = Board.vote(small, "ada@example.com", 1)
      {:ok, thin: thin, small: small}
    end

    test "on thin and small cards: up, toggle off, down, toggle off", %{
      conn: conn,
      thin: thin,
      small: small
    } do
      {:ok, view, _} = live(conn, "/team")
      assert has_element?(view, ~s(#tile-#{thin.id}[data-size="thin"]))
      assert has_element?(view, ~s(#tile-#{small.id}[data-size="small"]))

      for card <- [thin, small] do
        assert net(view, card.id) == "0"
        click(view, "#tile-#{card.id}-up")
        assert net(view, card.id) == "1"
        assert has_element?(view, ~s(#tile-#{card.id}-up[aria-pressed="true"]))
        click(view, "#tile-#{card.id}-up")
        assert net(view, card.id) == "0"
        click(view, "#tile-#{card.id}-down")
        assert net(view, card.id) == "-1"
        assert has_element?(view, "#tile-#{card.id} .badge-warning", "Needs work")
        click(view, "#tile-#{card.id}-down")
        assert net(view, card.id) == "0"
        refute has_element?(view, "#board-modal"), "a vote must not open the card"
      end
    end

    test "in the full dialog: up, toggle off, down; the tile count follows", %{
      conn: conn,
      small: small
    } do
      {:ok, view, _} = live(conn, "/team")
      view |> element("#tile-#{small.id} button[aria-haspopup]") |> render_click()
      up = "#card-#{small.id} button[phx-value-vote='1']"
      down = "#card-#{small.id} button[phx-value-vote='-1']"

      click(view, up)
      assert has_element?(view, ~s(#card-#{small.id} [aria-label="Net votes 1"]))
      assert net(view, small.id) == "1"
      click(view, up)
      assert has_element?(view, ~s(#card-#{small.id} [aria-label="Net votes 0"]))
      click(view, down)
      assert has_element?(view, "#card-#{small.id}-blocked")
      assert net(view, small.id) == "-1"
      assert has_element?(view, "#board-modal")
    end

    test "a bad vote value is refused on the card, not a crash", %{conn: conn, thin: thin} do
      {:ok, view, _} = live(conn, "/team")

      view
      |> with_target("#idea-board-live")
      |> render_click("vote", %{"card_id" => thin.id, "vote" => "2"})

      assert Process.alive?(view.pid)
      view |> element("#tile-#{thin.id} button[aria-haspopup]") |> render_click()
      assert has_element?(view, "#card-#{thin.id}-error", "A vote is +1 or -1.")
      assert net(view, thin.id) == "0"
    end
  end

  describe "merge approval on the card" do
    setup do
      {:ok, idea} =
        Board.link_pr(%{
          "number" => 125,
          "url" => "https://github.com/whyse-ab/ex-tales-forge/pull/125",
          "head_sha" => "abc1234def",
          "player_note" => "Brenna greets you by name.",
          "title" => "Brenna remembers regulars"
        })

      {:ok, idea: idea}
    end

    test "founders see the PR, the note and labelled Approve / Request changes; answers show in the log and history",
         %{conn: conn, idea: idea} do
      {:ok, view, _} = live(conn, "/team")
      open(view, idea)
      assert has_element?(view, "#card-#{idea.id}-pr a[href$='/pull/125']", "PR #125")

      assert has_element?(
               view,
               "#card-#{idea.id}-pr [data-role=player-note]",
               "Brenna greets you by name."
             )

      assert has_element?(
               view,
               ~s(#card-#{idea.id}-answer button[aria-label="Approve PR #125 for merge"])
             )

      assert has_element?(
               view,
               ~s(#card-#{idea.id}-answer button[aria-label="Request changes on PR #125"])
             )

      view
      |> form("#card-#{idea.id}-answer", %{comment: "Twice please"})
      |> render_submit(%{"answer" => "request_changes"})

      assert has_element?(view, "#card-#{idea.id}-approvals", "Changes requested")
      assert has_element?(view, "#card-#{idea.id}-approvals", "Twice please")

      view
      |> form("#card-#{idea.id}-answer", %{comment: "Good now"})
      |> render_submit(%{"answer" => "approve"})

      assert has_element?(view, "#card-#{idea.id}-approvals", "Approved")
      assert has_element?(view, "#board-col-building #tile-#{idea.id}")
      refute has_element?(view, "#card-#{idea.id}-answer")
      assert render(view) =~ "Approved PR #125 (abc1234): Good now"
    end
  end

  test "on playtest the placeholder stays", %{conn: conn} do
    Application.put_env(:ex_tales_forge, :app_name, "tales-forge-playtest")
    on_exit(fn -> Application.delete_env(:ex_tales_forge, :app_name) end)
    {:ok, view, _} = live(conn, "/team")
    assert has_element?(view, "#board-soon")
    refute has_element?(view, "#idea-board-live")
  end
end
