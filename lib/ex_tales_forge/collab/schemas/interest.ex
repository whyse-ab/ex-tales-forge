defmodule TalesForge.Collab.Schemas.Interest do
  @moduledoc """
  Self-selected interest on a decision. Never an assigned owner.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "collab_interests" do
    field :email, :string

    belongs_to :decision, TalesForge.Collab.Schemas.Decision

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(interest, attrs) do
    interest
    |> cast(attrs, [:decision_id, :email])
    |> validate_required([:decision_id, :email])
    |> update_change(:email, &String.downcase/1)
    |> unique_constraint([:decision_id, :email])
  end
end
