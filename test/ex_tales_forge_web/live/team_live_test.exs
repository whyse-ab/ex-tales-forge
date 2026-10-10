defmodule TalesForgeWeb.TeamLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  doctest TalesForgeWeb.TeamLive

  alias TalesForgeWeb.TeamBoard
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
        assert redirected_to(get(build_conn(), @path)) == "/admin/login"
        assert {:error, {:redirect, %{to: "/admin/login"}}} = live(build_conn(), @path)
      end

      test "a GitHub user outside the team is refused at #{path}" do
        conn = log_in_non_member(build_conn())
        assert redirected_to(get(conn, @path)) == "/admin/login"
      end

      test "a team member gets #{path}", %{conn: conn} do
        assert {:ok, _view, html} = live(log_in_admin(conn), @path)
        assert html =~ "How Tales Forge gets built"
      end
    end

    test "/team is linked from the admin nav", %{conn: conn} do
      {:ok, admin, _html} = live(log_in_admin(conn), ~p"/admin")
      assert has_element?(admin, ~s(#admin-nav a[href="/team"]), "Founders' page")
    end
  end

  describe "the landing page" do
    setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

    test "the hero is the painted crew, loaded first", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team")

      assert has_element?(view, "#landing-hero h1", "How Tales Forge gets built")

      assert has_element?(
               view,
               ~s(#landing-hero-art[src="/images/team/hero-960.jpg"][width="1280"][height="720"][loading="eager"][fetchpriority="high"])
             )

      assert has_element?(view, ~s(#landing-hero-art[alt*="The five founders"]))

      assert has_element?(
               view,
               ~s(#landing-hero-art[alt*="Max, our vibe-coding founder and RPG apprentice"])
             )

      assert has_element?(view, ~s(#landing-hero-art[alt*="Case, Bobby and Gentry"]))

      assert has_element?(
               view,
               "#landing-starting-point",
               "Right now Fredrik holds the approval key"
             )
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

      assert html =~ "6. How we&#39;ll work together: one shared board"
    end

    test "what we're going to do: the idea board's slot, coming soon", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/team")

      assert has_element?(view, "section#idea-board h2", "What we're going to do")
      assert has_element?(view, ~s(#idea-board #board-soon[data-slot="shared-board"]))
      assert has_element?(view, "#board-soon", "Coming soon. Not built yet.")
      assert has_element?(view, "#board-soon h3", "One shared board")

      assert has_element?(
               view,
               ~s(#board-soon a[href="/team/presentation##{TeamBoard.anchor()}"]),
               "How it will work"
             )

      # A placeholder, not a board.
      refute has_element?(view, "#board-soon #team-board")
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

      assert ids == ~w(landing-hero idea-board live presentation-cta)
    end

    test "null and missing numbers still render, never a zero" do
      html = render_with(%{})
      assert html =~ "The founders and not measured yet bots"
      assert html =~ "Numbers as of not measured yet"
      assert html =~ "Right now one founder holds the approval key"
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
