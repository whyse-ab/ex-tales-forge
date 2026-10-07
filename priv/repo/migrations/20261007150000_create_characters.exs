defmodule TalesForge.Repo.Migrations.CreateCharacters do
  @moduledoc """
  Phase 1 of docs/plan-unify-character.md (tales-forge-docs): one `characters`
  table for player characters and NPCs, plus `character_memories`, each
  character's own view of an event in the shared `session_events` table.

  Setup only: new sessions write these rows, nothing reads them yet, and no
  existing row is backfilled. `down` drops both tables.
  """

  use Ecto.Migration

  def change do
    create table(:characters, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :game_session_id, references(:game_sessions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :slug, :string, null: false
      add :controller, :string, null: false
      add :controller_ref, :string
      # No players table yet: ready for a character to belong to a player and carry over.
      add :owner_player_id, :string

      add :origin, :map, null: false, default: %{}
      add :definition, :map, null: false, default: %{}

      add :name, :string, null: false
      add :race, :string
      add :role, :string
      add :location_id, :string

      add :stats, :map, null: false, default: %{}
      add :skills, :map, null: false, default: %{}
      add :ocean, :map, null: false, default: %{}
      add :maslow_level, :string, null: false
      add :maslow_since_tick, :integer
      add :concerns, :map, null: false, default: fragment("'[]'::jsonb")
      add :inventory, :map, null: false, default: fragment("'[]'::jsonb")
      add :coins, :map, null: false, default: %{}

      add :wounds, :integer, null: false, default: 0
      add :wound_max, :integer, null: false, default: 3
      add :vitality, :string, null: false, default: "ok"
      add :learning_points, :map, null: false, default: %{}
      add :learning_failures, :map, null: false, default: %{}

      add :mood, :string
      add :relationships, :map, null: false, default: %{}
      add :runtime, :map, null: false, default: %{}

      add :lock_version, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create unique_index(:characters, [:game_session_id, :slug])
    create index(:characters, [:owner_player_id])

    create constraint(:characters, :characters_controller_check,
             check: "controller IN ('player', 'gm', 'bot')"
           )

    create constraint(:characters, :characters_maslow_level_check,
             check:
               "maslow_level IN ('physiological', 'safety', 'belonging', 'esteem', 'self_actualisation')"
           )

    create table(:character_memories, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :character_id, references(:characters, type: :binary_id, on_delete: :delete_all),
        null: false

      add :session_event_id,
          references(:session_events, type: :binary_id, on_delete: :nilify_all)

      add :kind, :string, null: false
      add :text, :text, null: false
      add :felt, :string
      add :salience, :float, null: false, default: 0.5
      add :secret, :boolean, null: false, default: false
      add :tick, :integer

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:character_memories, [:character_id, :tick])
    create index(:character_memories, [:session_event_id])

    create constraint(:character_memories, :character_memories_kind_check,
             check: "kind IN ('memory', 'promise', 'reaction', 'fact')"
           )
  end
end
