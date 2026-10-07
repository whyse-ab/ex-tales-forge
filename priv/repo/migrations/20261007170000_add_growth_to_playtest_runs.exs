defmodule TalesForge.Repo.Migrations.AddGrowthToPlaytestRuns do
  use Ecto.Migration

  # Skill growth in a playtest run (rolls, LP gained and improvements per
  # skill), written when the run ends, so the Jev baseline shows how fast
  # characters grow (tales-forge-docs decisions 2026-10-07, skill rules).
  def change do
    alter table(:playtest_runs) do
      add :growth, :map, null: false, default: %{}
    end
  end
end
