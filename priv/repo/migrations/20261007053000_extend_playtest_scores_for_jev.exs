defmodule TalesForge.Repo.Migrations.ExtendPlaytestScoresForJev do
  use Ecto.Migration

  def change do
    alter table(:playtest_scores) do
      add :source, :string, null: false, default: "llm"
      add :kind, :string, null: false, default: "rubric"
      add :turn_number, :integer
      add :confidence, :float
      add :probabilities, :map, null: false, default: %{}
    end

    create index(:playtest_scores, [:playtest_run_id, :kind, :inserted_at])
  end
end
