defmodule TalesForge.Schemas.Character do
  @moduledoc """
  Ecto schema: one character in a game session, player character or NPC alike.
  The `controller` (`player`, `gm` or `bot`) is the only difference.

  Characters live per session for now; `owner_player_id` is ready for a
  character that belongs to a player and carries over. `definition` is an
  immutable copy of the authored source; `origin` says where it came from.
  Phase 1 of the Character plan only writes these rows; nothing reads them yet.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias TalesForge.Characters.Levers
  alias TalesForge.Schemas.Character.{Concern, InventoryItem, Ocean, Stats}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @controllers ~w(player gm bot)
  @vitalities ~w(ok hurt down dead)

  @type t :: %__MODULE__{}

  schema "characters" do
    field :slug, :string
    field :controller, :string
    field :controller_ref, :string
    field :owner_player_id, :string
    field :origin, :map, default: %{}
    field :definition, :map, default: %{}

    field :name, :string
    field :race, :string
    field :role, :string
    field :location_id, :string

    embeds_one :stats, Stats, on_replace: :update
    field :skills, :map, default: %{}
    embeds_one :ocean, Ocean, on_replace: :update
    field :maslow_level, :string
    field :maslow_since_tick, :integer
    embeds_many :concerns, Concern, on_replace: :delete
    embeds_many :inventory, InventoryItem, on_replace: :delete
    field :coins, :map, default: %{}

    field :wounds, :integer, default: 0
    field :wound_max, :integer, default: 3
    field :vitality, :string, default: "ok"
    field :learning_points, :map, default: %{}
    field :learning_failures, :map, default: %{}

    field :mood, :string
    field :relationships, :map, default: %{}
    field :runtime, :map, default: %{}

    field :lock_version, :integer, default: 1

    belongs_to :game_session, TalesForge.Schemas.GameSession
    has_many :memories, TalesForge.Schemas.CharacterMemory

    timestamps(type: :utc_datetime)
  end

  @doc "The allowed controllers."
  def controllers, do: @controllers

  @fields ~w(game_session_id slug controller controller_ref owner_player_id origin definition
             name race role location_id skills maslow_level maslow_since_tick coins wounds
             wound_max vitality learning_points learning_failures mood relationships runtime)a

  def changeset(character, attrs) do
    character
    |> cast(attrs, @fields)
    |> cast_embed(:stats)
    |> cast_embed(:ocean)
    |> cast_embed(:concerns)
    |> cast_embed(:inventory)
    |> validate_required([:game_session_id, :slug, :controller, :name, :maslow_level])
    |> validate_inclusion(:controller, @controllers)
    |> validate_inclusion(:maslow_level, Levers.maslow_levels())
    |> validate_inclusion(:vitality, @vitalities)
    |> validate_number(:wounds, greater_than_or_equal_to: 0)
    |> validate_number(:wound_max, greater_than: 0)
    |> validate_concern_count()
    |> unique_constraint([:game_session_id, :slug])
    |> check_constraint(:controller, name: :characters_controller_check)
    |> check_constraint(:maslow_level, name: :characters_maslow_level_check)
    |> optimistic_lock(:lock_version)
  end

  defp validate_concern_count(changeset) do
    concerns = get_field(changeset, :concerns) || []

    if length(concerns) > Levers.max_concerns() do
      add_error(changeset, :concerns, "at most %{count} concerns", count: Levers.max_concerns())
    else
      changeset
    end
  end
end
