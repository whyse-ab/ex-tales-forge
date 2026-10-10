defmodule TalesForge.Repo.Migrations.TeamImages do
  use Ecto.Migration

  # One image store for the idea board's cards and the team chat
  # (TalesForge.Images). Each image belongs to one card or one chat message.
  def change do
    create table(:team_images, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :idea_id, references(:board_ideas, type: :binary_id, on_delete: :delete_all)
      add :message_id, references(:team_chat_messages, type: :binary_id, on_delete: :delete_all)
      add :uploader, :string, null: false
      add :content_type, :string, null: false
      add :byte_size, :integer, null: false
      add :note, :text
      add :data, :binary, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:team_images, [:idea_id])
    create index(:team_images, [:message_id])

    create constraint(:team_images, :one_owner,
             check: "(idea_id IS NULL) <> (message_id IS NULL)"
           )
  end
end
