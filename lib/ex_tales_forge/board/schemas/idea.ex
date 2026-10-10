defmodule TalesForge.Board.Idea do
  @moduledoc """
  A card on the founders' idea board (`board_ideas`): an idea with its column,
  Case's refinement, the founders' free-text tags (`tags`), the cached ranking score and, once a founder has OK'd it,
  the decision log entry it wrote (`decision_slug`, `decision_sha`). A card
  imported from the Collab decision queue points back at it
  (`collab_decision_id`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias TalesForge.Board.{Comment, Link, Transition, Vote}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @columns ~w(ideas refining check building done parked)

  @typedoc "A card."
  @type t :: %__MODULE__{}

  schema "board_ideas" do
    field :title, :string
    field :body, :string, default: ""
    field :column, :string, default: "ideas"
    field :author, :string
    field :refinement, :map, default: %{}
    field :score, :float, default: 0.0
    field :decision_sha, :string
    field :decision_slug, :string
    field :collab_decision_id, :binary_id
    field :pr_number, :integer
    field :pr_url, :string
    field :pr_head_sha, :string
    field :player_note, :string
    field :tags, {:array, :string}, default: []

    has_many :votes, Vote
    has_many :comments, Comment
    has_many :transitions, Transition
    has_many :links, Link
    has_many :approvals, TalesForge.Board.Approval
    has_many :answers, TalesForge.Board.Answer
    has_many :images, TalesForge.Images.Image

    timestamps(type: :utc_datetime)
  end

  @doc "The columns, in board order."
  @spec columns() :: [String.t()]
  def columns, do: @columns

  @doc "Changeset for a new idea (title, body, author)."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(idea, attrs) do
    idea
    |> cast(attrs, [:title, :body, :author, :column, :collab_decision_id])
    |> update_change(:title, &String.trim/1)
    |> validate_required([:title, :author])
    |> validate_length(:title, min: 3, max: 160)
    |> validate_length(:body, max: 20_000)
    |> validate_inclusion(:column, @columns)
    |> unique_constraint(:collab_decision_id)
  end

  @doc "Changeset for internal updates (column, refinement, score, decision)."
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(idea, attrs) do
    idea
    |> cast(attrs, [
      :column,
      :refinement,
      :score,
      :decision_sha,
      :decision_slug,
      :pr_number,
      :pr_url,
      :pr_head_sha,
      :player_note,
      :tags
    ])
    |> validate_inclusion(:column, @columns)
  end
end
