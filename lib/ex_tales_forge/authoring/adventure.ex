defmodule TalesForge.Authoring.Adventure do
  @moduledoc """
  Ash resource for authored Adventures (the "module" layer from three-layer architecture).

  An Adventure owns:
  - Metadata (name, synopsis, starting location)
  - Locations (world graph)
  - Cast (NpcDefinitions, referenced or embedded in future)

  For Phase 2 MVP we start simple (metadata + starting info).
  Full locations can be modeled as a separate Location resource with belongs_to adventure,
  or embedded maps initially. Materialization copies this into a GameSession's world_state.
  """

  use Ash.Resource,
    otp_app: :ex_tales_forge,
    domain: TalesForge.Authoring,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "adventures"
    repo(TalesForge.Repo)
  end

  attributes do
    uuid_primary_key :id

    attribute :adventure_id, :string do
      allow_nil? false
      public? true
      description "Stable slug, e.g. crossroads_ledger"
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :synopsis, :string do
      public? true
    end

    attribute :starting_location_id, :string do
      public? true
    end

    attribute :initial_present_npc_ids, {:array, :string} do
      public? true
      default []
    end

    # Future: opening_context_md, threads, overlay seed, etc. (can be :string or separate resources)

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # NpcDefinition and Location stay keyed by adventure_id; Ash relationships are not wired yet.

  actions do
    defaults [:read, :destroy]

    create :create do
      accept [
        :adventure_id,
        :name,
        :synopsis,
        :starting_location_id,
        :initial_present_npc_ids
      ]
    end

    update :update do
      primary? true

      accept [
        :name,
        :synopsis,
        :starting_location_id,
        :initial_present_npc_ids
      ]
    end
  end

  code_interface do
    define :create
    define :read
    define :update
    define :destroy

    # Custom lookup example: Adventure |> Ash.Query.filter(adventure_id == ^id) |> Ash.read_one!()
    # (or add a named :read action later)
  end

  identities do
    identity :unique_adventure_id, [:adventure_id]
  end
end
