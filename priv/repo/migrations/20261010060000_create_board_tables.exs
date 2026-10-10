defmodule TalesForge.Repo.Migrations.CreateBoardTables do
  @moduledoc """
  The founders' idea board (tales-forge-docs `docs/design-idea-board.md`):
  ideas (cards), one vote per founder per idea, comments, the append-only
  column history and links (PR, playtest, decision). A card may point at the
  Collab decision it was imported from (`collab_decision_id`).
  """
  use Ecto.Migration

  def change do
    create table(:board_ideas, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :body, :text, null: false, default: ""
      add :column, :string, null: false, default: "ideas"
      add :author, :string, null: false
      add :refinement, :map, null: false, default: %{}
      add :score, :float, null: false, default: 0.0
      add :decision_sha, :string
      add :decision_slug, :string

      add :collab_decision_id,
          references(:collab_decisions, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:board_ideas, [:column])
    create index(:board_ideas, [:score])
    create unique_index(:board_ideas, [:collab_decision_id])

    create table(:board_votes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :idea_id, references(:board_ideas, type: :binary_id, on_delete: :delete_all),
        null: false

      add :founder, :string, null: false
      add :value, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:board_votes, [:idea_id, :founder])
    create constraint(:board_votes, :value_is_plus_or_minus_one, check: "value IN (-1, 1)")

    create table(:board_comments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :idea_id, references(:board_ideas, type: :binary_id, on_delete: :delete_all),
        null: false

      add :author, :string, null: false
      add :body, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:board_comments, [:idea_id])

    create table(:board_transitions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :idea_id, references(:board_ideas, type: :binary_id, on_delete: :delete_all),
        null: false

      add :from, :string
      add :to, :string, null: false
      add :actor, :string, null: false
      add :note, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:board_transitions, [:idea_id])

    create table(:board_links, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :idea_id, references(:board_ideas, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :url, :text, null: false
      add :label, :string
      add :added_by, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:board_links, [:idea_id])
    create unique_index(:board_links, [:idea_id, :kind, :url])
  end
end
