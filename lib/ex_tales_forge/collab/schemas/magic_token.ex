defmodule TalesForge.Collab.Schemas.MagicToken do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "admin_magic_tokens" do
    field :email, :string
    field :token, :string
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:email, :token, :expires_at])
    |> validate_required([:email, :token, :expires_at])
    |> update_change(:email, &String.downcase/1)
    |> unique_constraint(:token)
  end
end
