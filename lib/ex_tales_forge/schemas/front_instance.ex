defmodule TalesForge.Schemas.FrontInstance do
  @moduledoc """
  Ecto schema: a front (a threat or pressure in the world) running in one game session, with its status and runtime state.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(live dormant spent)

  schema "front_instances" do
    field :front_id, :string
    field :status, :string, default: "live"
    field :definition, :map, default: %{}
    field :runtime_state, :map, default: %{}
    field :lock_version, :integer, default: 1

    belongs_to :game_session, TalesForge.Schemas.GameSession

    timestamps(type: :utc_datetime)
  end

  def changeset(front, attrs) do
    front
    |> cast(attrs, [:game_session_id, :front_id, :status, :definition, :runtime_state])
    |> validate_required([:game_session_id, :front_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:game_session_id, :front_id])
    |> optimistic_lock(:lock_version)
  end
end
