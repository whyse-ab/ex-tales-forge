defmodule TalesForgeWeb.AdminLive.DecisionLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.Collab
  alias TalesForge.Collab.Importer

  @fixture Path.expand("../../fixtures/tales_forge_docs", __DIR__)

  setup %{conn: conn} do
    assert {:ok, _} = Importer.import_from_path(@fixture)
    {:ok, conn: log_in_admin(conn)}
  end

  test "queue renders ranked decisions", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/decisions")
    assert html =~ "Decision queue"
    assert html =~ "Confirm the Elixir rewrite"
    assert html =~ "open"
  end

  test "rerank moves a decision up", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/decisions")

    before = Collab.list_decisions()
    second = Enum.at(before, 1)
    assert second.slug == "d-002-persona-scorecards"

    render_click(view, "move_up", %{"slug" => second.slug})

    after_list = Collab.list_decisions()
    assert hd(after_list).slug == "d-002-persona-scorecards"
  end

  test "record decision on show page", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/decisions/d-001-elixir-foundation")
    assert html =~ "Confirm the Elixir rewrite"
    assert html =~ "Record decision"

    render_submit(view, "record_decision", %{
      "decision" => "Commit to ex-tales-forge",
      "rationale" => "One foundation"
    })

    d = Collab.get_decision_by_slug!("d-001-elixir-foundation")
    assert d.status == "decided"
    assert d.decision == "Commit to ex-tales-forge"
    assert d.rationale =~ "foundation"
  end
end
