defmodule TalesForge.Surveys do
  @moduledoc """
  Founder surveys: answers stored per user, defined by JSON files in
  tales-forge-docs (`TalesForge.Survey.Source`, `TalesForge.Survey.Definition`).

  A user is the signed-in GitHub team member (`%{login: ..., email: ...}`);
  there is one `TalesForge.Survey.Response` per user per survey id. Saving a
  section stores its answers, the survey version each changed answer was
  given under, and the exact survey file (`TalesForge.Survey.Snapshot`).
  Saves are refused once the survey's `status` is `closed`.

  Several surveys can be open at once: `active/1` lists the founder tabs
  (every discovered survey file with `"active": true` that is not closed),
  `founder_status/2` says where a founder is with one survey, and
  `overview/1` gives every founder's status per survey for the admin.
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

  @typedoc "Where one founder is with one survey."
  @type founder_status :: :not_started | :in_progress | :done

  @typedoc "One survey in the admin overview: its definition (nil if it failed to load) and statuses by login."
  @type overview_row :: %{
          id: String.t(),
          definition: Definition.t() | nil,
          problems: [String.t()],
          responses: non_neg_integer(),
          statuses: %{optional(String.t()) => founder_status()}
        }

  @doc """
  The survey shown on `/admin/survey` when no survey is active or the docs
  can't be read at all (config `:current_survey`).
  """
  @spec current_id() :: String.t()
  def current_id, do: Application.get_env(:ex_tales_forge, :current_survey, "founder-survey-3")

  @doc """
  The founder tabs: every discovered survey that is active and not closed,
  loaded, in id order. Surveys that fail to load are left out (their
  problems show on their own page and in `overview/1`).
  """
  @spec active(keyword()) :: [Source.loaded()]
  def active(opts \\ []) do
    {ids, _problems} = Source.list_ids(opts)

    for id <- ids,
        {:ok, loaded} <- [Source.load(id)],
        Definition.active?(loaded.definition),
        do: loaded
  end

  @doc """
  Where a founder is with a survey: `:not_started` (no response or nothing
  answered), `:done` (every required question answered) or `:in_progress`.
  """
  @spec founder_status(Definition.t(), Response.t() | nil) :: founder_status()
  def founder_status(%Definition{}, nil), do: :not_started

  def founder_status(%Definition{} = definition, %Response{answers: answers}) do
    progress = Answers.progress(definition, answers || %{})

    cond do
      progress.answered == 0 -> :not_started
      progress.complete? -> :done
      true -> :in_progress
    end
  end

  @doc """
  A short label for a founder status.

      iex> TalesForge.Surveys.status_label(:in_progress)
      "In progress"
  """
  @spec status_label(founder_status()) :: String.t()
  def status_label(:not_started), do: "Not started"
  def status_label(:in_progress), do: "In progress"
  def status_label(:done), do: "Done"

  @doc """
  Every discovered survey (active or not, closed included) with each
  founder's status, plus every login that has answered any of them, sorted.
  """
  @spec overview(keyword()) :: %{
          surveys: [overview_row()],
          logins: [String.t()],
          problems: [String.t()]
        }
  def overview(opts \\ []) do
    {ids, problems} = Source.list_ids(opts)

    rows =
      Enum.map(ids, fn id ->
        case Source.load(id) do
          {:ok, loaded} ->
            overview_row(id, loaded)

          {:error, errors} ->
            %{id: id, definition: nil, problems: errors, responses: 0, statuses: %{}}
        end
      end)

    logins = rows |> Enum.flat_map(&Map.keys(&1.statuses)) |> Enum.uniq() |> Enum.sort()
    %{surveys: rows, logins: logins, problems: problems}
  end

  defp overview_row(id, %{definition: definition, problems: problems}) do
    responses = list_responses(definition.id)

    %{
      id: id,
      definition: definition,
      problems: problems,
      responses: Enum.count(responses, &(founder_status(definition, &1) != :not_started)),
      statuses: Map.new(responses, &{&1.github_login, founder_status(definition, &1)})
    }
  end

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
