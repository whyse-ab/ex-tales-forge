defmodule TalesForge.AdminResources.GameSession do
  @moduledoc """
  Ash resource for admin handling of GameSession (runtime "campaign" data).

  This resource is intended **only** for use by the admin UI and TalesForge.Admin
  context. The game play loop, Jido agents, Oban workers, etc. continue to use
  the plain Ecto schema `TalesForge.Schemas.GameSession` + direct Repo access.

  Points at the existing `game_sessions` table.
  """

  use Ash.Resource,
    otp_app: :ex_tales_forge,
    domain: TalesForge.AdminResources,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "game_sessions"
    repo(TalesForge.Repo)
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:active, :paused, :completed, :dead]
      default :active
      public? true
    end

    attribute :world_state, :map do
      public? true
      default %{}
    end

    attribute :world_clock, :utc_datetime do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :turns, TalesForge.AdminResources.Turn do
      destination_attribute :game_session_id
    end

    has_many :scenes, TalesForge.AdminResources.Scene do
      destination_attribute :game_session_id
    end

    has_many :npc_instances, TalesForge.AdminResources.NpcInstance do
      destination_attribute :game_session_id
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [:name, :status, :world_state, :world_clock]
    end

    update :update do
      primary? true
      accept [:name, :status, :world_state, :world_clock]
    end

    # Admin-specific action example (can be extended)
    update :update_world_state do
      accept [:world_state]
    end
  end

  code_interface do
    define :create
    define :read
    define :update
    define :destroy
  end
end
