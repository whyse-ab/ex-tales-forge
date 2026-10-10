defmodule TalesForge.Repo.Migrations.BoardPrApprovals do
  @moduledoc """
  Merge approvals on the idea board (decision 2026-10-10): a card can carry
  the PR waiting for a founder's OK, and every Approve / Request changes is
  kept in `board_approvals`.
  """
  use Ecto.Migration

  def change do
    alter table(:board_ideas) do
      add :pr_number, :integer
      add :pr_url, :string
      add :pr_head_sha, :string
      add :player_note, :text
    end

    create index(:board_ideas, [:pr_number])

    create table(:board_approvals, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :idea_id, references(:board_ideas, type: :binary_id, on_delete: :delete_all),
        null: false

      add :decision, :string, null: false
      add :founder, :string, null: false
      add :pr_number, :integer, null: false
      add :head_sha, :string
      add :comment, :text
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:board_approvals, [:idea_id])
  end
end
