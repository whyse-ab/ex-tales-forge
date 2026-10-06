defmodule TalesForge.Repo.Migrations.CreatePlaytestRuns do
  use Ecto.Migration

  def change do
    create table(:playtest_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :game_session_id,
          references(:game_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :persona, :string, null: false
      add :module, :string, null: false
      add :build, :string
      add :turn_limit, :integer, null: false
      add :turns_played, :integer, null: false, default: 0
      add :status, :string, null: false
      add :stop_reason, :string
      add :started_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create index(:playtest_runs, [:game_session_id])
    create index(:playtest_runs, [:status])
  end
end
