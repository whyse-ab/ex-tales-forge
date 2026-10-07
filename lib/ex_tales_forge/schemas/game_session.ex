defmodule TalesForge.Schemas.GameSession do
  @moduledoc """
  Ecto schema: a game session and its `world_state` map (character, location, NPCs, clock, moods).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "game_sessions" do
    field :name, :string
    field :status, :string, default: "active"
    field :world_state, :map, default: %{}
    field :world_clock, :utc_datetime

    has_many :turns, TalesForge.Schemas.Turn
    has_many :scenes, TalesForge.Schemas.Scene
    has_many :npc_instances, TalesForge.Schemas.NpcInstance
    has_many :front_instances, TalesForge.Schemas.FrontInstance
    has_many :session_events, TalesForge.Schemas.SessionEvent

    timestamps(type: :utc_datetime)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:name, :status, :world_state, :world_clock])
    |> validate_required([:name])
    |> validate_inclusion(:status, ["active", "paused", "completed", "dead"])
  end
end
