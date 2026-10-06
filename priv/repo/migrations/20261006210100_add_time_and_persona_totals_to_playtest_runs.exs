defmodule TalesForge.Repo.Migrations.AddTimeAndPersonaTotalsToPlaytestRuns do
  use Ecto.Migration

  def change do
    alter table(:playtest_runs) do
      add :game_ms, :integer, null: false, default: 0
      add :persona_calls, :integer, null: false, default: 0
      add :persona_ms, :integer, null: false, default: 0
      add :persona_input_tokens, :integer, null: false, default: 0
      add :persona_output_tokens, :integer, null: false, default: 0
      add :persona_cost_micro_usd, :bigint, null: false, default: 0
    end
  end
end
