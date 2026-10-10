defmodule TalesForgeWeb.TeamIdeaBoardTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.Board

  doctest TalesForgeWeb.TeamIdeaBoard

  setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

  defp downvote(view, id, reason) do
    view |> element("#tile-#{id}-down") |> render_click(%{"value" => ""})
    view |> form("#card-#{id}-downvote", %{reason: reason}) |> render_submit()
  end

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

    # Every card is thin: the full title wraps (no ellipsis), no task text.
    assert has_element?(view, ~s(#board-col-refining #tile-#{b.id}[data-size="thin"]))
    assert has_element?(view, ~s(#tile-#{b.id} [data-role="title"]), "Active one")
    refute render(view) =~ ~s(data-size="small")
    refute has_element?(view, ~s([data-role="task"]))
    refute has_element?(view, "#board-columns .truncate")
    refute has_element?(view, "#board-columns .line-clamp-2")
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

    assert has_element?(view, "#card-#{idea.id}-hold", "Put on hold")
    refute has_element?(view, "#card-#{idea.id}-back")
    view |> element("#card-#{idea.id}-forward", "Send to Refining") |> render_click()
    assert has_element?(view, "#board-col-refining #tile-#{idea.id}")

    # Case's refinement: read-only, with an Edit button that opens the form.
    assert has_element?(view, "p", "Case has not written it yet.")
    refute has_element?(view, "#card-#{idea.id}-refine")
    view |> element("#card-#{idea.id}-edit-refinement") |> render_click()

    view
    |> form("#card-#{idea.id}-refine", %{
      details: "Rods.",
      open_questions: "Where?\nBait?",
      rough_cost: "M",
      verdict: "feasible"
    })
    |> render_submit()

    refute has_element?(view, "#card-#{idea.id}-refine")
    assert has_element?(view, "#card-#{idea.id}-refinement", "Where? · Bait?")
    assert render(view) |> String.split("Where? · Bait?") |> length() == 2

    {:ok, _} = Board.move(Board.get_idea!(idea.id), {:bot, :case}, "check")
    send(view.pid, {:board, :changed})
    refute has_element?(view, "#card-#{idea.id}-edit-refinement")

    # Forward needs the open questions answered: it opens a comment box.
    assert has_element?(view, "#card-#{idea.id}-back", "Back to Refining")
    assert has_element?(view, "#card-#{idea.id}-forward", "Start building")
    assert has_element?(view, "#card-#{idea.id}-hold", "Put on hold")
    view |> element("#card-#{idea.id}-forward") |> render_click()
    assert has_element?(view, "#card-#{idea.id}-move textarea[required]")
    view |> element("#card-#{idea.id}-move button", "Cancel") |> render_click()
    refute has_element?(view, "#card-#{idea.id}-move")
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

    view |> element("#card-#{idea.id}-back") |> render_click()
    view |> form("#card-#{idea.id}-move", %{note: "Cheaper, please."}) |> render_submit()

    assert has_element?(view, "#board-col-refining #tile-#{idea.id}")

    view |> form("#card-#{idea.id}-comment", %{body: "Looks fun"}) |> render_submit()
    assert render(view) =~ "Looks fun"

    # Links are read-only for founders: bots add them through the API.
    refute has_element?(view, "#card-#{idea.id}-link")
    assert has_element?(view, "#board-modal", "No links yet.")
  end

  test "links: PR number, title and status from the PR feed, the playtest run, a PR badge on the thin card",
       %{conn: conn} do
    {:ok, idea} = Board.create_idea("bo@example.com", %{"title" => "Fishing"})
    url = "https://github.com/whyse-ab/ex-tales-forge/pull/127"
    {:ok, idea} = Board.add_link(idea, "bot:bobby", %{"kind" => "pr", "url" => url})

    {:ok, idea} =
      Board.add_link(idea, "bot:gentry", %{
        "kind" => "playtest",
        "url" => "https://tales-forge-playtest.fly.dev/admin/playtest/runs/abc",
        "label" => "batch 12"
      })

    assert {:error, "Bots add the links" <> _} =
             Board.add_link(idea, "bo@example.com", %{"kind" => "doc", "url" => "https://x/y"})

    feed = TalesForge.PrFeed.empty(:ok)

    item =
      TalesForge.PrFeedFixtures.item(127,
        title: "Thin cards everywhere",
        state: :merged,
        merged_at: DateTime.utc_now(),
        deployed: %{playtest: :deployed, production: :deployed}
      )

    TalesForge.PrFeed.publish(%{feed | items: [item]})
    on_exit(fn -> TalesForge.PrFeed.publish(TalesForge.PrFeed.empty(:not_configured)) end)

    {:ok, view, _} = live(conn, "/team")

    assert has_element?(
             view,
             ~s(#tile-#{idea.id}-pr.badge-success[aria-label="PR 127, on prod"]),
             "#127"
           )

    open(view, idea)

    assert has_element?(
             view,
             ~s(#card-#{idea.id}-links li[data-kind="pr"] a[href="#{url}"]),
             "PR #127"
           )

    assert has_element?(
             view,
             ~s(#card-#{idea.id}-links li[data-kind="pr"]),
             "Thin cards everywhere"
           )

    assert has_element?(view, ~s(#card-#{idea.id}-links [data-role="pr-status"]), "on prod")

    assert has_element?(
             view,
             ~s(#card-#{idea.id}-links li[data-kind="playtest"] a),
             "Playtest run: batch 12"
           )
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
      assert has_element?(view, "#card-#{idea.id}-forward[disabled]")

      assert has_element?(
               view,
               ~s(#card-#{idea.id}-forward[aria-describedby="card-#{idea.id}-forward-why"])
             )

      assert has_element?(
               view,
               "#card-#{idea.id}-forward-why",
               "Send to Refining: Needs an upvote."
             )

      refute has_element?(view, "#card-#{idea.id}-hold[disabled]")

      view
      |> with_target("#idea-board-live")
      |> render_hook("move", %{"card_id" => idea.id, "to" => "refining"})

      assert has_element?(view, "#card-#{idea.id}-error", "Needs an upvote.")
      assert has_element?(view, "#board-col-ideas #tile-#{idea.id}")

      downvote(view, idea.id, "Too big for now")
      assert has_element?(view, "#card-#{idea.id}-downvote-reasons", "Too big for now")
      assert has_element?(view, ~s(#tile-#{idea.id}.border-warning[data-needs-work="true"]))
      assert has_element?(view, "#tile-#{idea.id} .badge-warning", "Needs work")
      assert has_element?(view, "#tile-#{idea.id}-reason", "Has a downvote.")
      refute has_element?(view, ~s(#tile-#{idea.id}[data-faded="true"]))

      view |> element("#tile-#{idea.id}-up") |> render_click()
      refute has_element?(view, ~s(#tile-#{idea.id}[data-needs-work="true"]))
      refute has_element?(view, "#tile-#{idea.id}-reason")
      assert has_element?(view, ~s(#tile-#{idea.id}[data-moves="refining parked"]))

      open(view, idea)
      refute has_element?(view, "#card-#{idea.id}-downvote-reasons")
      view |> element("#card-#{idea.id}-forward") |> render_click()
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
              do: {:ok, _} = Board.vote(idea, "f#{n}@x", v, "Needs work")

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

    test "a vote on a thin card is inside its border, changes the count and does not open the card",
         %{conn: conn, thin: thin} do
      {:ok, view, _} = live(conn, "/team")
      assert has_element?(view, ~s(#tile-#{thin.id} button[aria-label="Upvote Thin one"]))
      assert has_element?(view, ~s(#tile-#{thin.id} button[aria-label="Downvote Thin one"]))
      refute has_element?(view, ~s(#tile-#{thin.id} button[aria-haspopup] #tile-#{thin.id}-up))

      click(view, "#tile-#{thin.id}-up")
      assert has_element?(view, ~s(#tile-#{thin.id}-up [data-role="up"]), "1")
      assert net(view, thin.id) == "1"
      refute has_element?(view, "#board-modal")

      click(view, "#tile-#{thin.id}-up")
      assert net(view, thin.id) == "0"
      refute has_element?(view, "#board-modal")
    end

    test "a -1 on a thin card opens the full card with the reason box (focused); the vote and reason save together",
         %{conn: conn, thin: thin} do
      {:ok, view, _} = live(conn, "/team")
      click(view, "#tile-#{thin.id}-down")
      assert has_element?(view, "#board-modal")
      assert has_element?(view, "#card-#{thin.id}-downvote-reason[required][phx-mounted]")
      assert net(view, thin.id) == "0"

      view |> form("#card-#{thin.id}-downvote", %{reason: " "}) |> render_submit()
      assert has_element?(view, "#card-#{thin.id}-error", "A downvote needs a reason.")
      assert net(view, thin.id) == "0"

      view |> form("#card-#{thin.id}-downvote", %{reason: "Bait is unclear"}) |> render_submit()
      refute has_element?(view, "#card-#{thin.id}-downvote")
      assert net(view, thin.id) == "-1"
      assert has_element?(view, ~s(#tile-#{thin.id}-down [data-role="down"]), "1")
      assert has_element?(view, "#card-#{thin.id}-downvote-reasons", "Bait is unclear")

      # Taking the -1 back clears its reason (no reason box this time).
      click(view, "#card-#{thin.id} button[phx-value-vote='-1']")
      refute has_element?(view, "#card-#{thin.id}-downvote-reasons")
      assert [] = Board.get_idea!(thin.id).votes
    end

    test "on every thin card: up, toggle off, down, toggle off", %{
      conn: conn,
      thin: thin,
      small: small
    } do
      {:ok, view, _} = live(conn, "/team")
      assert has_element?(view, ~s(#tile-#{thin.id}[data-size="thin"]))
      assert has_element?(view, ~s(#tile-#{small.id}[data-size="thin"]))

      for card <- [thin, small] do
        assert net(view, card.id) == "0"
        click(view, "#tile-#{card.id}-up")
        assert net(view, card.id) == "1"
        assert has_element?(view, ~s(#tile-#{card.id}-up[aria-pressed="true"]))
        click(view, "#tile-#{card.id}-up")
        assert net(view, card.id) == "0"
        refute has_element?(view, "#board-modal"), "a vote must not open the card"
        downvote(view, card.id, "Unclear")
        assert net(view, card.id) == "-1"
        assert has_element?(view, "#tile-#{card.id} .badge-warning", "Needs work")
        view |> element("#board-modal-close") |> render_click()
        click(view, "#tile-#{card.id}-down")
        assert net(view, card.id) == "0"
        refute has_element?(view, "#board-modal"), "taking back a -1 does not open the card"
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
      view |> form("#card-#{small.id}-downvote", %{reason: "Too big"}) |> render_submit()
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
