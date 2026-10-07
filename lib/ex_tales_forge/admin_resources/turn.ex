defmodule TalesForge.AdminResources.Turn do
  @moduledoc """
  Ash resource over the `turns` table, for the admin UI.
  """

  use Ash.Resource,
    otp_app: :ex_tales_forge,
    domain: TalesForge.AdminResources,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "turns"
    repo(TalesForge.Repo)
  end

  attributes do
    uuid_primary_key :id

    attribute :turn_number, :integer do
      allow_nil? false
      public? true
    end

    attribute :player_action, :string do
      allow_nil? false
      public? true
    end

    attribute :narrative, :string do
      public? true
    end

    attribute :mechanical_resolution, :map do
      public? true
      default %{}
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :game_session, TalesForge.AdminResources.GameSession do
      allow_nil? false
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]
    # Admin rarely creates turns manually; mostly read-only
  end

  code_interface do
    define :read
    define :destroy
  end
end
