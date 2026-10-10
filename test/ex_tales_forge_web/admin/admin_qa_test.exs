defmodule TalesForgeWeb.AdminQaTest do
  @moduledoc "Gentry's QA of the admin regroup (2026-10-10): redirects, return_to, doc links, a11y, labels."
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.AdminAuth
  alias TalesForge.Collab.Importer
  alias TalesForgeWeb.AdminSections

  doctest TalesForge.AdminAuth, only: [safe_return_to: 1]

  describe "redirects" do
    setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

    test "old /admin/telemetry keeps its query", %{conn: conn} do
      assert redirected_to(get(conn, "/admin/telemetry?x=1"), 302) ==
               "/admin/operate/telemetry?x=1"

      assert redirected_to(get(conn, "/admin/telemetry/home"), 302) ==
               "/admin/operate/telemetry/home"
    end

    test "section roots open their section on the admin home", %{conn: conn} do
      for {segment, anchor} <- [
            {"play", "section-play"},
            {"founders", "section-founders"},
            {"operate", "section-operate"},
            {"archive", "section-archive"},
            {"develop", "section-develop"}
          ] do
        assert redirected_to(get(conn, "/admin/#{segment}"), 302) == "/admin#" <> anchor
      end

      assert redirected_to(get(conn, "/admin/play?x=1"), 302) == "/admin?x=1#section-play"
    end

    test "a missing playtest run goes back to the list with the query", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/admin/play/runs/#{Ecto.UUID.generate()}?x=1")

      assert to == "/admin/play/runs?x=1"
    end
  end

  describe "return_to" do
    test "signed out: the login keeps the path and query" do
      conn = get(build_conn(), "/admin/play/runs?x=1&y=2")
      to = redirected_to(conn)

      assert to ==
               "/admin/login?" <> URI.encode_query(%{"return_to" => "/admin/play/runs?x=1&y=2"})

      {:ok, _view, html} = live(build_conn(), to)
      refute html =~ "github-login-off" and false

      assert get_session(conn, "admin_return_to") == "/admin/play/runs?x=1&y=2"
    end

    test "the sign-in button carries it; unsafe ones are dropped" do
      Application.put_env(:ex_tales_forge, :github_oauth, client_id: "id", client_secret: "s")
      on_exit(fn -> Application.delete_env(:ex_tales_forge, :github_oauth) end)

      {:ok, view, _} = live(build_conn(), "/admin/login?return_to=%2Fadmin%2Fdocs%3Fq%3D1")

      assert has_element?(
               view,
               ~s(#github-login[href="/admin/auth/github?return_to=%2Fadmin%2Fdocs%3Fq%3D1"])
             )

      {:ok, view, _} = live(build_conn(), "/admin/login?return_to=%2F%2Fevil.example")
      assert has_element?(view, ~s(#github-login[href="/admin/auth/github"]))
    end

    test "safe_return_to refuses other origins" do
      for bad <- ["//evil.example", "https://evil.example", "/\\evil", "evil", nil, "/a\nb"] do
        assert AdminAuth.safe_return_to(bad) == nil, inspect(bad)
      end
    end
  end

  describe "doc links open the doc" do
    setup %{conn: conn} do
      for path <- ~w(decisions.md roadmap-2027.md personas.md jev-scoring.md call-types.md
                     coding-standards.md environments.md architecture-baseline-2026-10-09.md
                     design-skills-economy.md design-stateful-world.md) do
        {:ok, _} =
          Importer.upsert_doc_markdown("# T #{path}\n\nBody of #{path}.", "docs/" <> path)
      end

      {:ok, conn: log_in_admin(conn)}
    end

    test "every doc link on the admin home opens its doc", %{conn: conn} do
      doc_items =
        for section <- AdminSections.sections(),
            item <- section.items,
            String.starts_with?(item.path, "/admin/docs/"),
            do: item.path

      assert length(doc_items) >= 10

      for path <- doc_items do
        {:ok, view, _html} = live(conn, path)
        assert has_element?(view, "#doc-preview article"), path
        refute has_element?(view, "#doc-missing"), path
        assert has_element?(view, "#admin-breadcrumbs [aria-current=page]"), path
      end
    end

    test "a doc that isn't anywhere stays on its URL and says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/docs/nope.md")
      assert has_element?(view, "#doc-missing", "docs/nope.md")
    end
  end

  describe "accessibility and labels" do
    setup %{conn: conn}, do: {:ok, conn: log_in_admin(conn)}

    test "skip link, menu name, named links", %{conn: conn} do
      {:ok, view, html} = live(conn, "/admin")
      assert has_element?(view, ~s(a#skip-to-content[href="#admin-main"]), "Skip to content")
      assert has_element?(view, "main#admin-main")
      assert has_element?(view, ~s(#admin-nav-menu summary[aria-label="Admin menu"]))

      assert has_element?(
               view,
               ~s{#admin-nav-archive a[aria-label="NPC definitions (base pack)"]}
             )

      assert html =~ "Decision log (doc)"
      assert html =~ "Decision queue (page)"
      assert html =~ "Logs (playtest)"
      assert html =~ "Gentry (presentation) ↗"
      assert html =~ "Founders&#39; page (/team) ↗"
    end

    test "breadcrumbs drop the label markers" do
      assert AdminSections.breadcrumbs("decisions") |> List.last() == {"Decision queue", nil}
    end
  end

  describe "pages without the admin layout" do
    test "code docs HTML gets a way back" do
      html =
        TalesForgeWeb.CodeDocsController.with_back_link(
          "<html><body class=x><p>hi</p></body></html>"
        )

      assert html =~ ~s(<body class=x><nav id="admin-back")
      assert html =~ ~s(href="/admin#section-develop")
      assert TalesForgeWeb.CodeDocsController.with_back_link("plain") == "plain"
    end
  end
end
