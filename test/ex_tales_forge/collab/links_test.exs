defmodule TalesForge.Collab.LinksTest do
  use ExUnit.Case, async: true

  alias TalesForge.Collab.Links

  doctest Links

  @gh "https://github.com/whyse-ab/tales-forge-docs"

  setup do
    known =
      Links.known(
        ["docs/personas.md", "docs/scripts/README.md"],
        [
          {"/srv/tales-forge-docs/decisions/d-008-tin-valley-starter.md",
           "d-008-tin-valley-starter"}
        ]
      )

    {:ok, known: known}
  end

  test "docs in the database open in the viewer, wherever the link starts", %{known: known} do
    assert Links.rewrite("personas.md", "docs/decisions.md", known) == "/admin/docs/personas.md"

    assert Links.rewrite("./personas.md#paul", "docs/a.md", known) ==
             "/admin/docs/personas.md#paul"

    assert Links.rewrite("../personas.md", "docs/scripts/README.md", known) ==
             "/admin/docs/personas.md"

    assert Links.rewrite("../docs/scripts/README.md", "decisions/d-001.md", known) ==
             "/admin/docs/scripts/README.md"
  end

  test "decisions open on their page, by file name", %{known: known} do
    assert Links.rewrite("../decisions/d-008-tin-valley-starter.md#why", "docs/x.md", known) ==
             "/admin/founders/decisions/d-008-tin-valley-starter#why"

    assert Links.rewrite("d-008-tin-valley-starter.md", "decisions/d-001.md", known) ==
             "/admin/founders/decisions/d-008-tin-valley-starter"
  end

  test "images under docs/ go through the doc image route", %{known: known} do
    assert Links.rewrite("images/score.PNG", "docs/analysis.md", known) ==
             "/admin/docs-files/docs/images/score.PNG"
  end

  test "other repo files and docs not synced yet go to GitHub", %{known: known} do
    assert Links.rewrite("founder-survey-2.md#q1", "docs/founder-survey-3.md", known) ==
             "#{@gh}/blob/main/docs/founder-survey-2.md#q1"

    assert Links.rewrite("scripts/jev-compare/", "docs/a.md", known) ==
             "#{@gh}/tree/main/docs/scripts/jev-compare"

    assert Links.rewrite("../worlds/merovingia", "docs/a.md", known) ==
             "#{@gh}/tree/main/worlds/merovingia"

    assert Links.rewrite("../decisions/README.md", "docs/a.md", known) ==
             "#{@gh}/blob/main/decisions/README.md"

    # Climbing above the repo root stays inside the repo.
    assert Links.rewrite("../../../etc/hosts.txt", "docs/a.md", known) ==
             "#{@gh}/blob/main/etc/hosts.txt"
  end

  test "absolute URLs, app paths, mail and same-page anchors stay as written", %{known: known} do
    for url <- [
          "https://github.com/whyse-ab/ex-tales-forge/pull/74",
          "https://tales-forge-playtest.fly.dev/admin/play/runs/761713eb-b3cd-4460-b4d0-34c7ba6f777c",
          "mailto:team@example.com",
          "/admin/play/runs",
          "#answers",
          ""
        ] do
      assert Links.rewrite(url, "docs/a.md", known) == url
    end
  end
end
