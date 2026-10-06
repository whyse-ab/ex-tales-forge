defmodule TalesForgeWeb.AdminLive.DocLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.Collab.Importer

  setup %{conn: conn} do
    {:ok, _} =
      Importer.upsert_doc_markdown(
        "# Roadmap 2027\n\nShip the *thing*.\n\n## Q1\n\nPlans.",
        "docs/roadmap-2027.md"
      )

    {:ok, conn: log_in_admin(conn)}
  end

  test "preview shows the doc title once, not again as the body's H1", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/docs")

    view
    |> element("#doc-files-mobile button[phx-value-path='docs/roadmap-2027.md']")
    |> render_click()

    preview = view |> element("#doc-preview") |> render()

    assert preview =~ "Roadmap 2027"
    assert length(String.split(preview, "Roadmap 2027")) == 2
    assert preview =~ "<h2"
    assert preview =~ "Q1"
    assert preview =~ "Plans."
  end

  test "inline and fenced code render inside the prose article", %{conn: conn} do
    {:ok, _} =
      Importer.upsert_doc_markdown(
        "# Code doc\n\nRun `mix test` first.\n\n```yaml\nturns: 14\n```\n",
        "docs/code-doc.md"
      )

    {:ok, view, _html} = live(conn, ~p"/admin/docs")

    view
    |> element("#doc-files-mobile button[phx-value-path='docs/code-doc.md']")
    |> render_click()

    # Inline span: a bare <code> directly in the paragraph (styled by `.prose :not(pre) > code`).
    assert has_element?(view, "#doc-preview article.prose p > code", "mix test")
    # Fenced block: <code> inside <pre>, so it only gets the block style.
    assert has_element?(view, "#doc-preview article.prose pre > code", "turns: 14")
  end
end
