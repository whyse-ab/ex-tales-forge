defmodule TalesForge.Schemas.PlaytestScore do
  @moduledoc """
  One judge scorecard for a playtest run (`TalesForge.Playtest.Scorer`).

  `scores` maps each scorecard criterion to `%{"score" => 1..5 | nil, "evidence" => text}`;
  nil means the session gave no chance to test it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "playtest_scores" do
    field :model, :string
    field :rubric_version, :string
    field :scores, :map, default: %{}
    field :overall, :float
    field :rationale, :string

    belongs_to :playtest_run, TalesForge.Schemas.PlaytestRun

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(score, attrs) do
    score
    |> cast(attrs, [:playtest_run_id, :model, :rubric_version, :scores, :overall, :rationale])
    |> validate_required([:playtest_run_id, :model, :rubric_version, :scores])
    |> foreign_key_constraint(:playtest_run_id)
  end
end
