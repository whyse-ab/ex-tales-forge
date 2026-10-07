defmodule TalesForge.Collab.ImporterTest do
  use TalesForge.DataCase, async: true

  alias TalesForge.Collab
  alias TalesForge.Collab.Importer

  @fixture Path.expand("../../fixtures/tales_forge_docs", __DIR__)

  test "imports decisions and docs from a local checkout" do
    assert {:ok, stats} = Importer.import_from_path(@fixture)
    assert stats.decisions.upserted == 3
    assert stats.docs.upserted >= 1
    assert stats.decisions.errors == []

    decisions = Collab.list_decisions()
    assert length(decisions) == 3

    assert Enum.map(decisions, & &1.slug) == [
             "d-001-elixir-foundation",
             "d-002-persona-scorecards",
             "d-012-closed-beta"
           ]

    first = hd(decisions)
    assert first.rank == 1
    assert first.status == "open"
    assert length(first.options) >= 2
    assert first.body =~ "Elixir rewrite"

    docs = Collab.list_docs()
    assert Enum.any?(docs, &(&1.path =~ "docs/"))
  end

  test "upserts by slug without duplicating" do
    assert {:ok, _} = Importer.import_from_path(@fixture)
    assert {:ok, stats} = Importer.import_from_path(@fixture)
    assert stats.decisions.upserted == 3
    assert length(Collab.list_decisions()) == 3
  end

  test "preserves recorded outcome on re-import" do
    assert {:ok, _} = Importer.import_from_path(@fixture)
    d = Collab.get_decision_by_slug!("d-001-elixir-foundation")

    assert {:ok, _} =
             Collab.record_decision(
               d,
               %{"decision" => "Commit to ex-tales-forge", "rationale" => "One stack"},
               "founder@example.com"
             )

    assert {:ok, _} = Importer.import_from_path(@fixture)
    d2 = Collab.get_decision_by_slug!("d-001-elixir-foundation")
    assert d2.status == "decided"
    assert d2.decision == "Commit to ex-tales-forge"
  end

  test "keeps a full ISO timestamp in decided_at" do
    dir = Path.join(System.tmp_dir!(), "tf-importer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "decisions"))
    on_exit(fn -> File.rm_rf!(dir) end)

    @fixture
    |> Path.join("decisions/d-012-closed-beta.md")
    |> File.read!()
    |> String.replace("decided_at:\n", "decided_at: \"2026-10-07T10:30:00Z\"\n")
    |> then(&File.write!(Path.join(dir, "decisions/d-012-closed-beta.md"), &1))

    assert {:ok, _} = Importer.import_from_path(dir)
    assert [%{decided_at: ~U[2026-10-07 10:30:00Z]}] = Collab.list_decisions()
  end
end
