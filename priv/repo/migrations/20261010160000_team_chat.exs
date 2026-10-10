defmodule TalesForge.Repo.Migrations.TeamChat do
  @moduledoc """
  Team chat (card "Team chat with mentions", 2026-10-10): one shared room for
  founders and bots. Each message keeps the founder handles it mentions, so
  the unread badge is one query. `team_chat_reads` holds when each founder
  last opened the chat.
  """
  use Ecto.Migration

  def change do
    create table(:team_chat_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :author, :string, null: false
      add :body, :text, null: false
      add :mentions, {:array, :string}, null: false, default: []
      add :bots, {:array, :string}, null: false, default: []
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:team_chat_messages, [:inserted_at])

    create table(:team_chat_reads, primary_key: false) do
      add :handle, :string, primary_key: true
      add :read_at, :utc_datetime_usec, null: false
    end
  end
end
