defmodule TalesForge.Repo.Migrations.CreatePlaytestScores do
  use Ecto.Migration

  def change do
    create table(:playtest_scores, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :playtest_run_id,
          references(:playtest_runs, type: :binary_id, on_delete: :delete_all),
          null: false

      add :model, :string, null: false
      add :rubric_version, :string, null: false
      add :scores, :map, null: false, default: %{}
      add :overall, :float
      add :rationale, :text

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:playtest_scores, [:playtest_run_id])
  end
end
