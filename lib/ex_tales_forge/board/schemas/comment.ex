defmodule TalesForge.Board.Comment do
  @moduledoc "A comment on a card (`board_comments`), by a founder (email) or a bot (`bot:case`)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @typedoc "A comment."
  @type t :: %__MODULE__{}

  schema "board_comments" do
    field :author, :string
    field :body, :string
    belongs_to :idea, TalesForge.Board.Idea
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Changeset: a non-empty body up to 10,000 characters."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:idea_id, :author, :body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:idea_id, :author, :body])
    |> validate_length(:body, min: 1, max: 10_000)
  end
end
