defmodule TalesForge.Repo.Migrations.BoardAnswers do
  @moduledoc """
  Answers to the open questions of Case's refinement (Fredrik, 2026-10-10):
  one row per card and question text, with the answer, who and when, and a
  "defer" flag. The questions stay in the refinement (a list of strings);
  existing cards need no data change (their questions start open).
  """
  use Ecto.Migration

  def change do
    create table(:board_answers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :idea_id, references(:board_ideas, type: :binary_id, on_delete: :delete_all),
        null: false

      add :question, :text, null: false
      add :answer, :text
      add :answered_by, :string
      add :answered_at, :utc_datetime_usec
      add :deferred, :boolean, null: false, default: false
      add :deferred_by, :string
      add :deferred_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:board_answers, [:idea_id, :question])
  end
end
