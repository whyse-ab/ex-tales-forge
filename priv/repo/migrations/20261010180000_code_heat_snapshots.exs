defmodule TalesForge.Repo.Migrations.CodeHeatSnapshots do
  @moduledoc """
  Code heat map (card "Code heat map", 2026-10-10): one row for each daily
  sample of call counts and call time (`TalesForge.CodeHeat`).
  """
  use Ecto.Migration

  def change do
    create table(:code_heat_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :app_name, :string, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec, null: false
      add :modules, :integer, null: false, default: 0
      add :rows, {:array, :map}, null: false, default: []
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:code_heat_snapshots, [:ended_at])
  end
end
