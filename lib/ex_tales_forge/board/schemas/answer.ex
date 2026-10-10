defmodule TalesForge.Board.Answer do
  @moduledoc """
  A founder's answer to one open question of Case's refinement
  (`board_answers`), or its deferral. Keyed by the card and the question
  text, so a question that Case rewrites starts open again.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @typedoc "An answer."
  @type t :: %__MODULE__{}

  schema "board_answers" do
    field :question, :string
    field :answer, :string
    field :answered_by, :string
    field :answered_at, :utc_datetime_usec
    field :deferred, :boolean, default: false
    field :deferred_by, :string
    field :deferred_at, :utc_datetime_usec
    belongs_to :idea, TalesForge.Board.Idea
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(answer, attrs) do
    answer
    |> cast(attrs, [
      :idea_id,
      :question,
      :answer,
      :answered_by,
      :answered_at,
      :deferred,
      :deferred_by,
      :deferred_at
    ])
    |> validate_required([:idea_id, :question])
    |> unique_constraint([:idea_id, :question])
  end

  @doc """
  True when the question is settled: answered or deferred.

      iex> TalesForge.Board.Answer.settled?(%TalesForge.Board.Answer{answer: "Yes"})
      true
      iex> TalesForge.Board.Answer.settled?(%TalesForge.Board.Answer{deferred: true})
      true
      iex> TalesForge.Board.Answer.settled?(%TalesForge.Board.Answer{answer: " "})
      false
      iex> TalesForge.Board.Answer.settled?(nil)
      false
  """
  @spec settled?(t() | nil) :: boolean()
  def settled?(%__MODULE__{deferred: true}), do: true
  def settled?(%__MODULE__{answer: a}) when is_binary(a), do: String.trim(a) != ""
  def settled?(_), do: false
end
