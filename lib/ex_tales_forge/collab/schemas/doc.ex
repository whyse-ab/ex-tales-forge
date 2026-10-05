defmodule TalesForge.Collab.Schemas.Doc do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "collab_docs" do
    field :path, :string
    field :title, :string
    field :body, :string, default: ""

    timestamps(type: :utc_datetime)
  end

  def changeset(doc, attrs) do
    doc
    |> cast(attrs, [:path, :title, :body])
    |> validate_required([:path, :title])
    |> unique_constraint(:path)
  end
end
