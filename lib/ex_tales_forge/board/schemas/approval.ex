defmodule TalesForge.Board.Approval do
  @moduledoc """
  A founder's answer to a PR waiting on a card (`board_approvals`),
  append-only: `approved` or `changes_requested`, who, when, which PR and its
  head sha, and the comment.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @decisions ~w(approved changes_requested)

  @typedoc "An approval."
  @type t :: %__MODULE__{}

  schema "board_approvals" do
    field :decision, :string
    field :founder, :string
    field :pr_number, :integer
    field :head_sha, :string
    field :comment, :string
    belongs_to :idea, TalesForge.Board.Idea
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Changeset for a new approval."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(approval, attrs) do
    approval
    |> cast(attrs, [:idea_id, :decision, :founder, :pr_number, :head_sha, :comment])
    |> validate_required([:idea_id, :decision, :founder, :pr_number])
    |> validate_inclusion(:decision, @decisions)
  end
end
