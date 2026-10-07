defmodule TalesForge.Schemas.SessionEvent do
  @moduledoc """
  Ecto schema: an event in a game session's log. `player_aware: false` events (GM reasoning, world facts) are never shown to the player.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "session_events" do
    field :kind, :string
    field :actor, :string
    field :player_aware, :boolean, default: true
    field :tick, :integer
    field :location_id, :string
    field :payload, :map, default: %{}

    belongs_to :game_session, TalesForge.Schemas.GameSession

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:game_session_id, :kind, :actor, :player_aware, :tick, :location_id, :payload])
    |> validate_required([:game_session_id, :kind, :tick])
  end
end
