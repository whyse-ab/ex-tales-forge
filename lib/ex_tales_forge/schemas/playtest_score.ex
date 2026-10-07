defmodule TalesForge.Schemas.PlaytestScore do
  @moduledoc """
  One scorecard or affect score for a playtest run.

  - `source`: `"llm"` (rubric judge) or `"jev"` (TypeSafe persona-affect).
  - `kind`: `"rubric"` (LLM scorecard), `"session_affect"` (whole-run Jev), or
    `"turn_affect"` (one turn's Jev score; `turn_number` set).
  - For Jev rows, `overall` is the 1–5 scale (`jev_score + 1`; Jev is 0-indexed),
    with `confidence` and `probabilities`. Evidence/rationale stay nil.
  - For LLM rows, `scores` maps criteria to `%{"score" => 1..5 | nil, "evidence" => text}`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @sources ~w(llm jev)
  @kinds ~w(rubric session_affect turn_affect)

  schema "playtest_scores" do
    field :model, :string
    field :rubric_version, :string
    field :scores, :map, default: %{}
    field :overall, :float
    field :rationale, :string
    field :source, :string, default: "llm"
    field :kind, :string, default: "rubric"
    field :turn_number, :integer
    field :confidence, :float
    field :probabilities, :map, default: %{}

    belongs_to :playtest_run, TalesForge.Schemas.PlaytestRun

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(score, attrs) do
    score
    |> cast(attrs, [
      :playtest_run_id,
      :model,
      :rubric_version,
      :scores,
      :overall,
      :rationale,
      :source,
      :kind,
      :turn_number,
      :confidence,
      :probabilities
    ])
    |> validate_required([:playtest_run_id, :model, :rubric_version, :scores, :source, :kind])
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:kind, @kinds)
    |> foreign_key_constraint(:playtest_run_id)
  end
end
