defmodule TalesForge.Board.Vote do
  @moduledoc "One founder's vote on an idea (`board_votes`): +1 or -1, one per founder per idea."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @typedoc "A vote."
  @type t :: %__MODULE__{}

  schema "board_votes" do
    field :founder, :string
    field :value, :integer
    field :reason, :string
    belongs_to :idea, TalesForge.Board.Idea
    timestamps(type: :utc_datetime)
  end

  @doc "Changeset: value must be 1 or -1; a -1 needs a reason, a +1 has none."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [:idea_id, :founder, :value, :reason])
    |> validate_required([:idea_id, :founder, :value])
    |> validate_inclusion(:value, [1, -1])
    |> then(fn cs ->
      if get_field(cs, :value) == -1,
        do: validate_required(cs, [:reason], message: "is necessary for a downvote"),
        else: put_change(cs, :reason, nil)
    end)
    |> unique_constraint([:idea_id, :founder])
  end
end
