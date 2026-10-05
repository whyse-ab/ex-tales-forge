defmodule TalesForge.Repo.Migrations.CreateCollabTables do
  use Ecto.Migration

  def change do
    create table(:collab_decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :string, null: false
      add :title, :string, null: false
      add :rank, :integer, null: false, default: 999
      add :status, :string, null: false, default: "open"
      add :options, {:array, :string}, null: false, default: []
      add :decision, :string
      add :rationale, :text
      add :decided_at, :utc_datetime
      add :links, {:array, :string}, null: false, default: []
      add :body, :text, null: false, default: ""
      add :source_path, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:collab_decisions, [:slug])
    create index(:collab_decisions, [:rank])
    create index(:collab_decisions, [:status])

    create table(:collab_comments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :decision_id, references(:collab_decisions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :author_email, :string, null: false
      add :body, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:collab_comments, [:decision_id])

    create table(:collab_interests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :decision_id, references(:collab_decisions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :email, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:collab_interests, [:decision_id, :email])
    create index(:collab_interests, [:email])

    create table(:collab_docs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :path, :string, null: false
      add :title, :string, null: false
      add :body, :text, null: false, default: ""

      timestamps(type: :utc_datetime)
    end

    create unique_index(:collab_docs, [:path])

    create table(:admin_magic_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :token, :string, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:admin_magic_tokens, [:token])
    create index(:admin_magic_tokens, [:email])
  end
end
