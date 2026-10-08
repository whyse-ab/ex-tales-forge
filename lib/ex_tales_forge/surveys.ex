defmodule TalesForge.Surveys do
  @moduledoc """
  Founder surveys: answers stored per user, defined by JSON files in
  tales-forge-docs (`TalesForge.Survey.Source`, `TalesForge.Survey.Definition`).

  A user is the signed-in GitHub team member (`%{login: ..., email: ...}`);
  there is one `TalesForge.Survey.Response` per user per survey id. Saving a
  section stores its answers, the survey version each changed answer was
  given under, and the exact survey file (`TalesForge.Survey.Snapshot`).
  Saves are refused once the survey's `status` is `closed`.
  """

  import Ecto.Query

  alias TalesForge.Repo
  alias TalesForge.Survey.Answers
  alias TalesForge.Survey.Definition
  alias TalesForge.Survey.Response
  alias TalesForge.Survey.Section
  alias TalesForge.Survey.Snapshot
  alias TalesForge.Survey.Source

  @typedoc "The signed-in user answering."
  @type user :: %{login: String.t(), email: String.t() | nil}

  @doc "The survey id the admin nav links to (config `:current_survey`)."
  @spec current_id() :: String.t()
  def current_id, do: Application.get_env(:ex_tales_forge, :current_survey, "founder-survey-3")

  @doc "This user's response to `survey_id`, or nil."
  @spec get_response(String.t(), String.t()) :: Response.t() | nil
  def get_response(survey_id, login) when is_binary(login) do
    Repo.get_by(Response, survey_id: survey_id, github_login: normalize_login(login))
  end

  @doc "Every response to `survey_id`, by login."
  @spec list_responses(String.t()) :: [Response.t()]
  def list_responses(survey_id) do
    Response
    |> where([r], r.survey_id == ^survey_id)
    |> order_by([r], asc: r.github_login)
    |> Repo.all()
  end

  @doc """
  Saves one section's posted `params` for `user`. Returns the updated
  response, `{:error, :closed}` for a closed survey or `{:error, :unknown_section}`.
  """
  @spec save_section(Source.loaded(), user(), String.t(), map()) ::
          {:ok, Response.t()} | {:error, :closed | :unknown_section | Ecto.Changeset.t()}
  def save_section(%{definition: definition} = loaded, user, section_id, params) do
    with :ok <- check_answerable(definition),
         %Section{} = section <- Definition.section(definition, section_id) || :unknown do
      section_answers = Answers.from_params(section, params)
      do_save(loaded, user, section_id, section_answers)
    else
      :unknown -> {:error, :unknown_section}
      error -> error
    end
  end

  @doc "Deletes this user's response (the 'clear my answers' button). Refused once closed."
  @spec clear_response(Source.loaded(), String.t()) :: :ok | {:error, :closed}
  def clear_response(%{definition: definition}, login) do
    with :ok <- check_answerable(definition) do
      Response
      |> where([r], r.survey_id == ^definition.id)
      |> where([r], r.github_login == ^normalize_login(login))
      |> Repo.delete_all()

      :ok
    end
  end

  @doc "The stored survey files for `survey_id`, oldest first."
  @spec list_snapshots(String.t()) :: [Snapshot.t()]
  def list_snapshots(survey_id) do
    Snapshot
    |> where([s], s.survey_id == ^survey_id)
    |> order_by([s], asc: s.inserted_at)
    |> select([s], %{s | body: nil})
    |> Repo.all()
  end

  @doc """
  Lowercased, trimmed GitHub login (GitHub logins are case-insensitive).

      iex> TalesForge.Surveys.normalize_login(" Octo-Cat ")
      "octo-cat"
  """
  @spec normalize_login(String.t()) :: String.t()
  def normalize_login(login), do: login |> String.trim() |> String.downcase()

  defp check_answerable(definition) do
    if Definition.answerable?(definition), do: :ok, else: {:error, :closed}
  end

  defp do_save(%{definition: definition} = loaded, user, section_id, section_answers) do
    login = normalize_login(user.login)
    record_snapshot(loaded)

    response =
      get_response(definition.id, login) ||
        %Response{survey_id: definition.id, github_login: login}

    changed = Answers.changed_questions(response.answers, section_answers)
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    versions =
      Enum.reduce(changed, response.answer_versions, &Map.put(&2, &1, definition.version))

    attrs = %{
      email: user[:email] || response.email,
      answers: Answers.merge(response.answers, section_answers),
      answer_versions: versions,
      sections_saved_at: Map.put(response.sections_saved_at, section_id, now),
      survey_version: definition.version,
      definition_sha256: loaded.sha256,
      saved_in_draft: response.saved_in_draft or definition.status == :draft
    }

    response
    |> Response.changeset(attrs)
    |> Repo.insert_or_update()
  end

  defp record_snapshot(loaded) do
    Repo.insert_all(
      Snapshot,
      [
        %{
          survey_id: loaded.definition.id,
          version: loaded.definition.version,
          sha256: loaded.sha256,
          source: loaded.source,
          body: loaded.raw,
          inserted_at: DateTime.utc_now()
        }
      ],
      on_conflict: :nothing,
      conflict_target: :sha256
    )
  end
end
