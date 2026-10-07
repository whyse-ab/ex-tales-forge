defmodule TalesForge.Repo.Migrations.AddTtftMsToAiCalls do
  use Ecto.Migration

  # Time to first token for streamed calls (prose GM). Null for non-streamed calls.
  def change do
    alter table(:ai_calls) do
      add :ttft_ms, :integer
    end
  end
end
