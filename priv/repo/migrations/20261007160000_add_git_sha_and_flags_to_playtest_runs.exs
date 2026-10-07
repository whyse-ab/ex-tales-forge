defmodule TalesForge.Repo.Migrations.AddGitShaAndFlagsToPlaytestRuns do
  use Ecto.Migration

  # The release's git commit and the flags in force when a playtest run started,
  # so runs can be grouped by build and condition (tales-forge-docs
  # docs/analysis-jev-scores-2026-10-07.md, recommendation 11).
  def change do
    alter table(:playtest_runs) do
      add :git_sha, :string
      add :flags, :map, null: false, default: %{}
    end

    create index(:playtest_runs, [:git_sha])
  end
end
