defmodule TalesForge.AdminResources.Scene do
  @moduledoc """
  Ash resource over the `scenes` table, for the admin UI.
  """

  use Ash.Resource,
    otp_app: :ex_tales_forge,
    domain: TalesForge.AdminResources,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "scenes"
    repo(TalesForge.Repo)
  end

  attributes do
    uuid_primary_key :id

    attribute :location_id, :string do
      allow_nil? false
      public? true
    end

    attribute :location_name, :string do
      allow_nil? false
      public? true
    end

    attribute :narrative, :string do
      allow_nil? false
      public? true
    end

    attribute :image_url, :string do
      public? true
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
  end

  code_interface do
    define :read
    define :destroy
  end
end
