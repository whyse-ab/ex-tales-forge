defmodule TalesForge.Schemas.NpcInstance do
  @moduledoc """
  Ecto schema: an NPC as it exists in one game session (personality, runtime state, disposition).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "npc_instances" do
    field :npc_id, :string
    field :personality, :map, default: %{}
    field :runtime_state, :map, default: %{}
    field :disposition, :float, default: 0.0

    belongs_to :game_session, TalesForge.Schemas.GameSession

    timestamps(type: :utc_datetime)
  end

  def changeset(npc_instance, attrs) do
    npc_instance
    |> cast(attrs, [:game_session_id, :npc_id, :personality, :runtime_state, :disposition])
    |> validate_required([:game_session_id, :npc_id])
    |> unique_constraint([:game_session_id, :npc_id])
  end
end
