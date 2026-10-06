defmodule TalesForge.Authoring.NpcDefinition do
  @moduledoc """
  Ash resource for authored NPC definitions (pre-play content).

  Matches the schema used in priv/npcs/*.json and text-forge adventures/.../npcs/*/npc.json:
  - Core identity + lore (name, race, role, appearance, personality, backstory)
  - Motivations block (OCEAN traits, primary_need, current_concern, mood, agency)
  - Stock for merchants
  - default_location_id for seeding
  - portrait_url (for Tigris images in Phase 2)

  Runtime state (mood deltas, memories, relationship, current stock qty) lives in NpcInstance.
  """

  use Ash.Resource,
    otp_app: :ex_tales_forge,
    domain: TalesForge.Authoring,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("npc_definitions")
    repo(TalesForge.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute :npc_id, :string do
      allow_nil?(false)
      public?(true)
      description("Stable slug/id, e.g. marta_kellen (unique per adventure in future)")
    end

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :race, :string do
      public?(true)
      default("human")
    end

    attribute :role, :string do
      public?(true)
    end

    attribute :default_location_id, :string do
      public?(true)
    end

    attribute :appearance, :string do
      public?(true)
    end

    attribute :personality, :string do
      public?(true)
    end

    attribute :backstory, :string do
      public?(true)
    end

    attribute :motivations, :map do
      public?(true)
      default(%{})

      description(
        "OCEAN + Maslow + current_concern + mood + agency (see text-forge NpcMotivations)"
      )
    end

    attribute :stock, {:array, :map} do
      public?(true)
      default([])
      description("Authored merchant stock (base quantities); runtime quantities in NpcInstance")
    end

    attribute :portrait_url, :string do
      public?(true)
      description("URL to authored/generated portrait (Tigris or external)")
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([
        :npc_id,
        :name,
        :race,
        :role,
        :default_location_id,
        :appearance,
        :personality,
        :backstory,
        :motivations,
        :stock,
        :portrait_url
      ])
    end

    update :update do
      primary?(true)

      accept([
        :name,
        :role,
        :default_location_id,
        :appearance,
        :personality,
        :backstory,
        :motivations,
        :stock,
        :portrait_url
      ])
    end
  end

  code_interface do
    define(:create)
    define(:read)
    define(:update)
    define(:destroy)

    # For lookup by npc_id (stable slug):
    #   NpcDefinition |> Ash.Query.filter(npc_id == "marta_kellen") |> Ash.read_one!()
  end

  identities do
    # For Phase 1/2, npc_id is globally unique; later scope to adventure_id
    identity(:unique_npc_id, [:npc_id])
  end
end
