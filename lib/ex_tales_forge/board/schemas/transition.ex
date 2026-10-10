defmodule TalesForge.Board.Transition do
  @moduledoc """
  One column move of a card (`board_transitions`), append-only: the card's
  history and the audit trail (who OK'd it, the decision commit).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @typedoc "A transition."
  @type t :: %__MODULE__{}

  schema "board_transitions" do
    field :from, :string
    field :to, :string
    field :actor, :string
    field :note, :string
    belongs_to :idea, TalesForge.Board.Idea
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Changeset for a new transition."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(transition, attrs) do
    transition
    |> cast(attrs, [:idea_id, :from, :to, :actor, :note])
    |> validate_required([:idea_id, :to, :actor])
  end
end
