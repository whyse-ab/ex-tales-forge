defmodule TalesForge.Collab.Schemas.Comment do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "collab_comments" do
    field :author_email, :string
    field :body, :string

    belongs_to :decision, TalesForge.Collab.Schemas.Decision

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:decision_id, :author_email, :body])
    |> validate_required([:decision_id, :author_email, :body])
    |> validate_length(:body, min: 1, max: 10_000)
  end
end
