defmodule TalesForge.Survey.Response do
  @moduledoc """
  One user's answers to one survey (`survey_responses`), keyed by survey id
  and lowercased GitHub login: there is at most one per user per survey, and
  it is edited in place until the survey closes.

    * `answers` – question id (or `"<question id>.<sub id>"` for follow-ups,
      "other" text and "why") to the answer: a string, a list of strings, an
      integer (scales) or a row → column map (grids).
    * `answer_versions` – question id to the survey `version` it was last
      answered under.
    * `sections_saved_at` – section id to the ISO 8601 time it was last saved.
    * `survey_version` / `definition_sha256` – the definition of the last save
      (the file itself is in `TalesForge.Survey.Snapshot`).
    * `saved_in_draft` – some answers were saved while the survey was a draft.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @typedoc "A stored response."
  @type t :: %__MODULE__{
          id: integer() | nil,
          survey_id: String.t() | nil,
          github_login: String.t() | nil,
          email: String.t() | nil,
          answers: map(),
          answer_versions: map(),
          sections_saved_at: map(),
          survey_version: integer() | nil,
          definition_sha256: String.t() | nil,
          saved_in_draft: boolean(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "survey_responses" do
    field :survey_id, :string
    field :github_login, :string
    field :email, :string
    field :answers, :map, default: %{}
    field :answer_versions, :map, default: %{}
    field :sections_saved_at, :map, default: %{}
    field :survey_version, :integer
    field :definition_sha256, :string
    field :saved_in_draft, :boolean, default: false

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for a save."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(response, attrs) do
    response
    |> cast(attrs, [
      :survey_id,
      :github_login,
      :email,
      :answers,
      :answer_versions,
      :sections_saved_at,
      :survey_version,
      :definition_sha256,
      :saved_in_draft
    ])
    |> validate_required([:survey_id, :github_login])
    |> unique_constraint([:survey_id, :github_login])
  end
end
