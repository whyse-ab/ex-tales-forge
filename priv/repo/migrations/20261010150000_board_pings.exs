defmodule TalesForge.Repo.Migrations.BoardPings do
  @moduledoc """
  Founder pings on the idea board (card "Chatt/Comment ping others",
  2026-10-10): a comment that names a founder (`@hakan`) adds an unread ping.
  """
  use Ecto.Migration

  def change do
    create table(:board_pings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :idea_id, references(:board_ideas, type: :binary_id, on_delete: :delete_all),
        null: false

      add :comment_id, references(:board_comments, type: :binary_id, on_delete: :delete_all),
        null: false

      add :handle, :string, null: false
      add :author, :string, null: false
      add :read_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:board_pings, [:handle, :read_at])
    create index(:board_pings, [:idea_id])
  end
end
