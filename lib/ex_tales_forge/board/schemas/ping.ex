defmodule TalesForge.Board.Ping do
  @moduledoc """
  A ping to a founder (`board_pings`): a comment named them (`@hakan`) or
  all founders (`@founders`). It stays unread until the founder opens the card.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @typedoc "A ping."
  @type t :: %__MODULE__{}

  schema "board_pings" do
    field :handle, :string
    field :author, :string
    field :read_at, :utc_datetime_usec
    belongs_to :idea, TalesForge.Board.Idea
    belongs_to :comment, TalesForge.Board.Comment
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Changeset."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(ping, attrs) do
    ping
    |> cast(attrs, [:idea_id, :comment_id, :handle, :author, :read_at])
    |> validate_required([:idea_id, :comment_id, :handle, :author])
  end
end
