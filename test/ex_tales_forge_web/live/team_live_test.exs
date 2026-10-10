defmodule TalesForgeWeb.TeamLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  doctest TalesForgeWeb.TeamLive

  alias TalesForgeWeb.TeamLive
  alias TalesForgeWeb.TeamPresentationLive

  @data "priv/team/data.json" |> File.read!() |> Jason.decode!()

  defp render_with(data),
    do:
      rendered_to_string(
        TeamLive.render(%{d: data, nav: [], anchors: "[]", aliases: "{}", flash: %{}})
      )

  defp ids(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("[id]")
    |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))
  end

  describe "sign-in: the same team login for both pages" do
    for path <- ["/team", "/team/presentation"] do
      @path path

      test "signed out, #{path} redirects to the login page" do
        assert redirected_to(get(build_conn(), @path)) =~ ~r{^/admin/login(\?|$)}
        assert {:error, {:redirect, %{to: "/admin/login" <> _}}} = live(build_conn(), @path)
      end

      test "a GitHub user outside the team is refused at #{path}" do
        conn = log_in_non_member(build_conn())
        assert redirected_to(get(conn, @path)) =~ ~r{^/admin/login(\?|$)}
      end

      test "a team member gets #{path}", %{conn: conn} do
        assert {:ok, _view, html} = live(log_in_admin(conn), @path)
        assert html =~ ~s(id="team-page")
      end
    end

    test "/team is linked from the admin nav", %{conn: conn} do
      {:ok, admin, _html} = live(log_in_admin(conn), ~p"/admin")
      assert has_element?(admin, ~s(#admin-nav a[href="/team"]), "Founders' page")
    end
  end

  describe "the landing page" do
    setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

    test "the workspace header replaces the hero; the hero stays on the presentation",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/team")

      assert has_element?(view, "#workspace h1#workspace-title", "Our workspace")

      assert has_element?(
               view,
               "#workspace-subtitle",
               "Ideas, building and chat for the whole crew"
             )

      refute has_element?(view, "#landing-hero")
      refute has_element?(view, "#landing-hero-art")
      refute has_element?(view, "#landing-starting-point")
      refute html =~ "How Tales Forge gets built"
      refute html =~ "approval key"

      {:ok, _pres, pres} = live(conn, ~p"/team/presentation")
      assert pres =~ "approval key"
    end

    test "the quick stats are links to the board, all zero on an empty board", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team")

      assert has_element?(view, ~s(nav#workspace-stats[aria-label="Quick stats"]))

      for {id, href, label} <- [
            {"stat-ideas", "#board-col-ideas", "Ideas waiting for votes"},
            {"stat-check", "#board-col-check", "Founder check cards for you"},
            {"stat-prs", "#board-col-building", "PRs waiting for approval"}
          ] do
        assert has_element?(view, ~s(a##{id}[href="#{href}"]), label)
        assert has_element?(view, ~s(##{id} [data-count]), "0")
      end

      # No pings: the board has no #board-pings, so the stat is plain text.
      refute has_element?(view, "#board-pings")
      assert has_element?(view, "div#stat-pings", "Pings for you")
      assert has_element?(view, "#stat-pings [data-count]", "0")
      refute has_element?(view, "a#stat-pings")
    end

    test "the stats count the board for the signed-in founder and update live" do
      me = "me@example.com"
      conn = log_in_admin(build_conn(), me, login: "fpahlen")
      alias TalesForge.Board

      {:ok, _} = Board.create_idea("bo@example.com", %{"title" => "One"})
      {:ok, _} = Board.create_idea("bo@example.com", %{"title" => "Two"})

      # Founder check: one card I voted on (not for me), one I did not (for me),
      # one I voted on that has an open question with no answer (for me).
      check = fn title, refinement ->
        {:ok, i} = Board.create_idea("bo@example.com", %{"title" => title})

        i
        |> Ecto.Changeset.change(column: "check", refinement: refinement)
        |> TalesForge.Repo.update!()
      end

      voted = check.("Voted", %{})
      {:ok, _} = Board.vote(Board.get_idea!(voted.id), me, 1)
      _not_voted = check.("Not voted", %{})
      asks = check.("Asks", %{"open_questions" => ["How big?"]})
      {:ok, _} = Board.vote(Board.get_idea!(asks.id), me, 1)

      {:ok, _} =
        Board.link_pr(%{
          "number" => 150,
          "url" => "https://github.com/whyse-ab/ex-tales-forge/pull/150",
          "head_sha" => "abc1234",
          "player_note" => "Nothing changes for players.",
          "title" => "Pings"
        })

      {:ok, view, _html} = live(conn, ~p"/team")

      assert has_element?(view, "#stat-ideas [data-count]", "2")
      assert has_element?(view, "#stat-check [data-count]", "2")
      assert has_element?(view, "#stat-prs [data-count]", "1")
      assert has_element?(view, "#stat-pings [data-count]", "0")

      {:ok, _} = Board.add_comment(Board.get_idea!(voted.id), "bot:case", "@fredrik a look?")
      send(view.pid, {:board, :changed})
      assert has_element?(view, "#stat-pings [data-count]", "1")
      assert has_element?(view, ~s(a#stat-pings[href="#board-pings"]))
      assert has_element?(view, "#board-pings")
    end

    test "the crew section is gone: it lives on the presentation", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team")
      refute has_element?(view, "#crew")
      refute has_element?(view, "#crew-cards")
    end

    test "the presentation is linked once, from its own card", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/team")

      assert has_element?(view, ~s(#presentation-link.team-cta[href="/team/presentation"]))
      refute has_element?(view, "#hero-presentation-link")
      refute has_element?(view, "#team-nav-presentation")
      refute has_element?(view, "#presentation-contents")

      links =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query(~s(a[href="/team/presentation"]))
        |> Enum.count()

      assert links == 1

      assert {:ok, _presentation, html} =
               view |> element("#presentation-link") |> render_click() |> follow_redirect(conn)

      assert html =~ "6. How we work together: one shared board"
    end

    test "no placeholder: playtest redirects /team to production", %{conn: conn} do
      Application.put_env(:ex_tales_forge, :app_name, "tales-forge-playtest")
      on_exit(fn -> Application.delete_env(:ex_tales_forge, :app_name) end)

      assert {:error, {:redirect, %{to: "https://tales-forge.fly.dev/team"}}} =
               live(conn, ~p"/team")

      Application.delete_env(:ex_tales_forge, :app_name)
      {:ok, _view, html} = live(conn, ~p"/team")
      refute html =~ "board-soon"
      refute html =~ "Coming soon. Not built yet."
    end

    test "what we're doing now: the live PR, CI and deploy feed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team")
      assert has_element?(view, "section#live h2", "What we're doing now")
    end

    test "light: the presentation's sections stay on the presentation", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/team")

      for id <- ~w(how infrastructure playtests pace together flow team-flow team-lanes) do
        refute id in ids(html), id
      end

      refute html =~ "Hostile play"
    end

    test "sections in order: hero, going to do, doing now, the presentation" do
      ids =
        @data
        |> render_with()
        |> LazyHTML.from_document()
        |> LazyHTML.query("main > section")
        |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))

      assert ids == ~w(workspace idea-board live presentation-cta)
    end

    test "null and missing numbers still render, never a zero" do
      html = render_with(%{})
      assert html =~ "Bundled numbers as of not measured yet"
    end

    test "the nav wraps on a phone: no sideways-scroll classes", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/team")
      assert has_element?(view, "#team-nav-list.flex-wrap")
      refute html =~ ~r/class="[^"]*\b(?:overflow-x-(?:auto|scroll)|whitespace-nowrap)\b/
    end
  end

  describe "old /team#section links" do
    setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

    test "the hook gets the presentation's anchors and where to send them", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/team")

      assert has_element?(
               view,
               ~s(#team-anchor-redirect[phx-hook="TeamAnchorRedirect"][data-target="/team/presentation"][hidden])
             )

      [anchors] =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#team-anchor-redirect")
        |> LazyHTML.attribute("data-anchors")

      assert Jason.decode!(anchors) == TeamPresentationLive.anchors()

      [aliases] =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("#team-anchor-redirect")
        |> LazyHTML.attribute("data-aliases")

      assert Jason.decode!(aliases) == TeamLive.aliases()
    end

    test "the old crew anchors land on the crew in the presentation" do
      presentation = MapSet.new(TeamPresentationLive.anchors())

      for {old, "/team/presentation#" <> anchor} <- TeamLive.aliases() do
        assert anchor in presentation, old
        refute old in TeamLive.anchors(), old
      end
    end

    test "every section and named part of the old /team maps to the presentation" do
      for {id, _label} <- TeamPresentationLive.sections(),
          do: assert(TeamPresentationLive.presentation_path(id) == "/team/presentation##{id}")

      for id <- ~w(team how infrastructure playtests pace together hero flow architecture
                   shadow-test eval-set gentry hostile-play ai-spend member-case
                   the-call-type-rule-one-turn-three-call-types) do
        assert TeamPresentationLive.presentation_path(id) == "/team/presentation##{id}", id
      end

      assert TeamPresentationLive.presentation_path("board") == "/team/presentation#board"
      assert TeamPresentationLive.presentation_path("nope") == nil
      assert TeamPresentationLive.presentation_path("") == nil
    end

    test "the landing page's own anchors are never redirected", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/team")
      landing_ids = ids(html)

      for anchor <- TeamLive.anchors() do
        assert anchor in landing_ids, anchor
        assert TeamPresentationLive.presentation_path(anchor) == nil, anchor
      end

      assert MapSet.disjoint?(MapSet.new(landing_ids), MapSet.new(TeamPresentationLive.anchors()))
    end

    test "the hook only forwards known anchors and replaces the URL" do
      js = File.read!("assets/js/team_hooks.js")
      [_, hook] = String.split(js, "export const presentationTarget", parts: 2)

      assert hook =~ "anchors.includes(anchor) ? `${target}#${anchor}` : null"
      assert hook =~ "return aliases[anchor]"
      assert hook =~ "window.location.replace(to)"
      assert hook =~ ~s{window.addEventListener("hashchange", this.onHash)}
      assert File.read!("assets/js/app.js") =~ "TeamAnchorRedirect"
    end
  end
end
