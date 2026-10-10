defmodule TalesForgeWeb.AdminLive.AdminReorgTest do
  @moduledoc """
  The admin area grouped by purpose (decision 2026-10-10): every old admin URL
  redirects to its new place (query and trailing slash kept, sign-in first),
  the nav shows the groups with a collapsed Archive, and the admin home shows
  one card per section.
  """
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.AdminPaths
  alias TalesForgeWeb.AdminSections

  doctest TalesForge.AdminPaths
  doctest TalesForgeWeb.AdminSections

  @run_id "761713eb-b3cd-4460-b4d0-34c7ba6f777c"

  # Every old admin URL (one per route) and where it lives now.
  @redirects [
    {"/admin/sessions", "/admin/play/sessions"},
    {"/admin/sessions/abc", "/admin/play/sessions/abc"},
    {"/admin/sessions/abc/npcs", "/admin/play/sessions/abc/npcs"},
    {"/admin/sessions/abc/npcs/marta", "/admin/play/sessions/abc/npcs/marta"},
    {"/admin/sessions/abc/turns", "/admin/play/sessions/abc/turns"},
    {"/admin/playtest", "/admin/play/runs"},
    {"/admin/playtest/#{@run_id}", "/admin/play/runs/#{@run_id}"},
    {"/admin/survey", "/admin/founders/survey"},
    {"/admin/surveys", "/admin/founders/surveys"},
    {"/admin/surveys/founder-survey-3", "/admin/founders/surveys/founder-survey-3"},
    {"/admin/surveys/founder-survey-3/results",
     "/admin/founders/surveys/founder-survey-3/results"},
    {"/admin/surveys/founder-survey-3/results.csv",
     "/admin/founders/surveys/founder-survey-3/results.csv"},
    {"/admin/surveys/founder-survey-3/results.md",
     "/admin/founders/surveys/founder-survey-3/results.md"},
    {"/admin/decisions", "/admin/founders/decisions"},
    {"/admin/decisions/d-008-tin-valley-starter",
     "/admin/founders/decisions/d-008-tin-valley-starter"},
    {"/admin/costs", "/admin/operate/costs"},
    {"/admin/oban", "/admin/operate/telemetry"},
    {"/admin/oban/home", "/admin/operate/telemetry/home"},
    {"/admin/npc-definitions", "/admin/archive/npc-definitions"},
    {"/admin/npc-definitions/marta_kellen", "/admin/archive/npc-definitions/marta_kellen"}
  ]

  describe "old URLs" do
    setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

    test "every old admin URL redirects to its new place (302)", %{conn: conn} do
      for {old, new} <- @redirects do
        conn = get(conn, old)
        assert conn.status == 302, "#{old} answered #{conn.status}"
        assert redirected_to(conn) == new, "#{old} went to #{redirected_to(conn)}"
        assert AdminPaths.canonical(old) == new
      end
    end

    test "the query string and a trailing slash are kept", %{conn: conn} do
      assert redirected_to(get(conn, "/admin/surveys/founder-survey-3/results?user=ada")) ==
               "/admin/founders/surveys/founder-survey-3/results?user=ada"

      assert redirected_to(get(conn, "/admin/sessions/")) == "/admin/play/sessions/"
    end

    # The survey pages need the survey source stubbed: their new paths are
    # covered in survey_live_test.exs.
    test "every redirect target is a real page", %{conn: conn} do
      for new <- [
            "/admin/play/sessions",
            "/admin/play/runs",
            "/admin/founders/decisions",
            "/admin/operate/costs",
            "/admin/archive/npc-definitions"
          ] do
        assert conn |> get(new) |> html_response(200), "#{new} is not a page"
      end

      assert {:ok, _view, _html} = live(conn, "/admin/operate/telemetry/home")
    end

    test "unchanged URLs are not redirected", %{conn: conn} do
      for path <- ["/admin", "/admin/docs", "/team", "/team/presentation"] do
        assert conn |> get(path) |> html_response(200)
      end

      assert AdminPaths.canonical("/admin/code-docs/") == "/admin/code-docs/"
    end

    test "signed out, an old URL goes to the sign-in first, not to the page" do
      for {old, _new} <- @redirects do
        assert build_conn() |> get(old) |> redirected_to() =~ ~r{^/admin/login(\?|$)},
               "#{old} skipped the sign-in"
      end
    end
  end

  describe "nav and home" do
    setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

    test "the nav groups the pages by purpose, Archive collapsed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/play/sessions")

      for {group, label} <- [
            {"founders", "Founder survey"},
            {"founders", "Decision queue"},
            {"play", "Playtest runs"},
            {"play", "Game sessions"},
            {"operate", "Costs"},
            {"operate", "Telemetry and AI calls"},
            {"develop", "Code docs"},
            {"docs", "All docs"}
          ] do
        assert has_element?(view, "#admin-nav-#{group} a", label), "#{label} not in #{group}"
      end

      assert has_element?(view, ~s(#admin-nav-play a[aria-current="page"]), "Game sessions")
      assert has_element?(view, "#admin-nav-archive:not([open]) a", "NPC definitions")
    end

    test "an archived page opens the Archive and is marked current", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/archive/npc-definitions")

      assert has_element?(
               view,
               ~s(#admin-nav-archive[open] a[aria-current="page"]),
               "NPC definitions"
             )

      assert has_element?(view, "#admin-nav-menu > summary", "Archive · NPC definitions")
    end

    test "the home shows each section as a card with one line and its links", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin")

      for section <- AdminSections.sections(), section.id != :archive do
        assert has_element?(view, "#section-#{section.id} h3", section.title)
        assert has_element?(view, "#section-#{section.id} p", section.line)

        for item <- section.items,
            do: assert(has_element?(view, "#section-#{section.id} a", item.label))
      end

      assert has_element?(view, "details#section-archive:not([open])", "NPC definitions")
      assert has_element?(view, "#at-a-glance", "Turns")
      assert has_element?(view, ~s(#section-operate a[target="_blank"]), "Logs (production)")

      assert has_element?(
               view,
               ~s(#section-play a[href="/admin/play/runs#batch-character-changes"])
             )
    end

    test "every section has a one-line summary and every item a path" do
      for section <- AdminSections.sections() do
        refute section.line =~ "\n"
        assert section.items != []
        for item <- section.items, do: assert(String.starts_with?(item.path, ["/", "https://"]))
      end

      keys = for s <- AdminSections.sections(), i <- s.items, i[:key], do: i.key
      assert keys == Enum.uniq(keys)
    end
  end
end
