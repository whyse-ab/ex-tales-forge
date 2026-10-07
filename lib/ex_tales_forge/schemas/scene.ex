defmodule TalesForge.Schemas.Scene do
  @moduledoc """
  Ecto schema: a scene (opening or arrival narration at a location).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "scenes" do
    field :location_id, :string
    field :location_name, :string
    field :narrative, :string
    field :image_url, :string

    belongs_to :game_session, TalesForge.Schemas.GameSession

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(scene, attrs) do
    scene
    |> cast(attrs, [:game_session_id, :location_id, :location_name, :narrative, :image_url])
    |> validate_required([:game_session_id, :location_id, :location_name, :narrative])
    |> unique_constraint([:game_session_id, :location_id])
  end
end
