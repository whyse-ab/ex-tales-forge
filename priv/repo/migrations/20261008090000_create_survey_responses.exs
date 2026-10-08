defmodule TalesForge.Repo.Migrations.CreateSurveyResponses do
  use Ecto.Migration

  def change do
    # One row per user per survey: the founder survey page autosaves into it.
    create table(:survey_responses) do
      add :survey_id, :string, null: false
      add :github_login, :string, null: false
      add :email, :string
      add :answers, :map, null: false, default: %{}
      add :answer_versions, :map, null: false, default: %{}
      add :sections_saved_at, :map, null: false, default: %{}
      add :survey_version, :integer
      add :definition_sha256, :string
      add :saved_in_draft, :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:survey_responses, [:survey_id, :github_login])

    # Every distinct survey file answers were saved under, verbatim, so an
    # answer can always be read next to the exact question text it answered.
    create table(:survey_definitions) do
      add :survey_id, :string, null: false
      add :version, :integer, null: false
      add :sha256, :string, null: false
      add :source, :string
      add :body, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:survey_definitions, [:sha256])
    create index(:survey_definitions, [:survey_id, :version])
  end
end
