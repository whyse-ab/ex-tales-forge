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
    {:ok, _view, html} = live(conn, ~p"/admin/founders/decisions")
    assert html =~ "Decision queue"
    assert html =~ "Confirm the Elixir rewrite"
    assert html =~ "open"
  end

  test "rerank moves a decision up", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/founders/decisions")

    before = Collab.list_decisions()
    second = Enum.at(before, 1)
    assert second.slug == "d-002-persona-scorecards"

    render_click(view, "move_up", %{"slug" => second.slug})

    after_list = Collab.list_decisions()
    assert hd(after_list).slug == "d-002-persona-scorecards"
  end

  test "record decision on show page", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/founders/decisions/d-001-elixir-foundation")
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

  describe "read-only once imported into the idea board" do
    setup do
      d = Collab.get_decision_by_slug!("d-001-elixir-foundation")
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      TalesForge.Repo.insert_all("board_ideas", [
        %{
          id: Ecto.UUID.bingenerate(),
          title: d.title,
          author: "import",
          collab_decision_id: Ecto.UUID.dump!(d.id),
          inserted_at: now,
          updated_at: now
        }
      ])

      :ok
    end

    test "the queue shows the notice and no reorder buttons; moving is refused", %{conn: conn} do
      assert Collab.read_only?()
      {:ok, view, html} = live(conn, ~p"/admin/founders/decisions")
      assert html =~ "decisions-read-only"
      refute html =~ ~s(phx-click="move_up")

      before = Enum.map(Collab.list_decisions(), & &1.slug)
      render_click(view, "move_up", %{"slug" => "d-002-persona-scorecards"})
      assert Enum.map(Collab.list_decisions(), & &1.slug) == before
    end

    test "the show page has no forms and refuses changes", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/founders/decisions/d-001-elixir-foundation")
      refute html =~ ~s(phx-submit="record_decision")
      refute html =~ ~s(phx-submit="add_comment")
      assert html =~ "Read-only"

      render_submit(view, "record_decision", %{"decision" => "x", "rationale" => "y"})
      render_submit(view, "add_comment", %{"body" => "hello"})
      render_click(view, "toggle_interested", %{})

      d = Collab.get_decision_by_slug!("d-001-elixir-foundation")
      assert d.status != "decided"
      assert d.comments == []
      assert d.interests == []
    end
  end

  test "not read-only before the import" do
    refute Collab.read_only?()
  end
end
