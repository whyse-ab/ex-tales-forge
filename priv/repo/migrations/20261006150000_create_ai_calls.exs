defmodule TalesForge.Repo.Migrations.CreateAiCalls do
  use Ecto.Migration

  def change do
    create table(:ai_calls, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :game_session_id,
          references(:game_sessions, type: :binary_id, on_delete: :nilify_all)

      add :turn_number, :integer
      add :purpose, :string, null: false
      add :model, :string, null: false
      add :status, :string, null: false
      add :latency_ms, :integer, null: false
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :cached_tokens, :integer
      add :reasoning_tokens, :integer
      add :cost_micro_usd, :bigint
      add :cost_source, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:ai_calls, [:game_session_id])
    create index(:ai_calls, [:inserted_at])
  end
end
