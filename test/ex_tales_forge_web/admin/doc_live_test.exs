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
    |> element("#doc-files-mobile a[data-path='docs/roadmap-2027.md']")
    |> render_click()

    assert_patch(view, "/admin/docs/roadmap-2027.md")
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

    {:ok, view, _html} = live(conn, ~p"/admin/docs/code-doc.md")

    # Inline span: a bare <code> directly in the paragraph (styled by `.prose :not(pre) > code`).
    assert has_element?(view, "#doc-preview article.prose p > code", "mix test")
    # Fenced block: <code> inside <pre>, so it only gets the block style.
    assert has_element?(view, "#doc-preview article.prose pre > code", "turns: 14")
  end

  test "every doc has its own URL; an unknown one goes back to the list", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/docs/roadmap-2027.md")
    assert html =~ "Plans."
    assert has_element?(view, "#doc-preview h2#q1", "Q1")

    assert {:error, {:live_redirect, %{to: "/admin/docs"}}} =
             live(conn, ~p"/admin/docs/not-synced.md")
  end

  describe "links inside a doc" do
    setup do
      {:ok, _} =
        Importer.upsert_doc_markdown(
          """
          # Survey

          - [sibling](roadmap-2027.md)
          - [sibling heading](roadmap-2027.md#q1)
          - [same page](#answers)
          - [not synced](founder-survey-2.md)
          - [decision](../decisions/d-008-tin-valley-starter.md#why)
          - [decisions readme](../decisions/README.md)
          - [script](scripts/jev-rescore/rescore.exs)
          - [script folder](scripts/jev-compare/)
          - [world file](../worlds/merovingia/game-system.json)
          - [admin page](/admin/play/runs)
          - [pull request](https://github.com/whyse-ab/ex-tales-forge/pull/74)
          - [mail](mailto:team@example.com)

          ![Score by turn](images/score.png)

          ## Answers

          Text.
          """,
          "docs/survey.md"
        )

      {:ok, _} =
        Importer.upsert_decision_markdown(
          "---\nid: d-008-tin-valley-starter\ntitle: Tin Valley\nrank: 1\n---\n## Why\n\nSee [the survey](../docs/survey.md#answers).",
          "decisions/d-008-tin-valley-starter.md"
        )

      dir = Path.join(System.tmp_dir!(), "docs_repo_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, "docs/images"))
      File.write!(Path.join(dir, "docs/images/score.png"), <<137, 80, 78, 71>>)
      Application.put_env(:ex_tales_forge, :tales_forge_docs_path, dir)

      on_exit(fn ->
        Application.delete_env(:ex_tales_forge, :tales_forge_docs_path)
        File.rm_rf!(dir)
      end)
    end

    test "are rewritten to admin pages, the doc image route or GitHub", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/docs/survey.md")

      gh = "https://github.com/whyse-ab/tales-forge-docs"

      expected = %{
        "sibling" => "/admin/docs/roadmap-2027.md",
        "sibling heading" => "/admin/docs/roadmap-2027.md#q1",
        "same page" => "#answers",
        "not synced" => "#{gh}/blob/main/docs/founder-survey-2.md",
        "decision" => "/admin/founders/decisions/d-008-tin-valley-starter#why",
        "decisions readme" => "#{gh}/blob/main/decisions/README.md",
        "script" => "#{gh}/blob/main/docs/scripts/jev-rescore/rescore.exs",
        "script folder" => "#{gh}/tree/main/docs/scripts/jev-compare",
        "world file" => "#{gh}/blob/main/worlds/merovingia/game-system.json",
        "admin page" => "/admin/play/runs",
        "pull request" => "https://github.com/whyse-ab/ex-tales-forge/pull/74",
        "mail" => "mailto:team@example.com"
      }

      for {text, href} <- expected do
        assert has_element?(view, ~s(#doc-preview article a[href="#{href}"]), text),
               "#{text}: expected href #{href}"
      end

      assert has_element?(
               view,
               ~s(#doc-preview article img[src="/admin/docs-files/docs/images/score.png"])
             )

      assert has_element?(view, "#doc-preview article h2#answers")
    end

    test "every rewritten internal link resolves, anchors included", %{conn: conn} do
      for page <- [
            ~p"/admin/docs/survey.md",
            ~p"/admin/founders/decisions/d-008-tin-valley-starter"
          ] do
        {:ok, _view, html} = live(conn, page)

        doc = LazyHTML.from_document(html)
        article = LazyHTML.query(doc, "article")

        links =
          (article |> LazyHTML.query("a[href]") |> LazyHTML.attribute("href")) ++
            (article |> LazyHTML.query("img[src]") |> LazyHTML.attribute("src"))

        internal =
          for link <- links,
              uri = URI.merge(URI.parse("http://app.test" <> page), link),
              uri.host == "app.test",
              do: uri

        assert internal != []

        for uri <- internal do
          target = conn |> recycle() |> log_in_admin() |> get(uri.path)
          assert target.status == 200, "#{page}: #{URI.to_string(uri)} answered #{target.status}"

          if uri.fragment do
            ids = target.resp_body |> LazyHTML.from_document() |> LazyHTML.query("[id]")

            assert uri.fragment in LazyHTML.attribute(ids, "id"),
                   "#{page}: #{URI.to_string(uri)} has no ##{uri.fragment}"
          end
        end
      end
    end
  end
end
