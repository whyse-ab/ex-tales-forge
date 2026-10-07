defmodule TalesForge.AdminResources.NpcInstance do
  @moduledoc """
  Ash resource over the `npc_instances` table, for the admin UI.
  """

  use Ash.Resource,
    otp_app: :ex_tales_forge,
    domain: TalesForge.AdminResources,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "npc_instances"
    repo(TalesForge.Repo)
  end

  attributes do
    uuid_primary_key :id

    attribute :npc_id, :string do
      allow_nil? false
      public? true
    end

    attribute :personality, :map do
      public? true
      default %{}
    end

    attribute :runtime_state, :map do
      public? true
      default %{}
    end

    attribute :disposition, :float do
      public? true
      default 0.0
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :game_session, TalesForge.AdminResources.GameSession do
      allow_nil? false
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    update :update do
      primary? true
      accept [:personality, :runtime_state, :disposition]
    end
  end

  code_interface do
    define :read
    define :update
    define :destroy
  end
end
