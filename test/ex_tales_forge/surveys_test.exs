defmodule TalesForge.SurveysTest do
  use TalesForge.DataCase, async: false

  @moduletag :capture_log

  import TalesForge.SurveyFixtures

  alias TalesForge.Survey.Source
  alias TalesForge.Surveys

  doctest Surveys

  setup do
    snapshot_only()
    use_docs_dir(survey_json())
    {:ok, loaded} = Source.load("test-survey")
    {:ok, loaded: loaded, user: %{login: "Ada", email: "ada@example.com"}}
  end

  test "founder status: not started, in progress, done", %{loaded: loaded, user: user} do
    d = loaded.definition
    assert Surveys.founder_status(d, nil) == :not_started

    {:ok, r} = Surveys.save_section(loaded, user, "general", %{"pace" => "3"})
    assert Surveys.founder_status(d, r) == :in_progress

    {:ok, r} = Surveys.save_section(loaded, user, "general", %{"one" => "Yes", "pace" => "3"})
    assert Surveys.founder_status(d, r) == :in_progress

    {:ok, r} = Surveys.save_section(loaded, user, "paul", %{"paul-excerpt" => "Too low"})
    assert Surveys.founder_status(d, r) == :done

    assert Surveys.founder_status(d, %{r | answers: %{}}) == :not_started
    assert Surveys.status_label(:done) == "Done"
    assert Surveys.status_label(:not_started) == "Not started"
  end

  test "active lists the open tabs only; overview lists every survey with statuses" do
    three_surveys()
    assert ["open-survey"] = Enum.map(Surveys.active(), & &1.definition.id)

    {:ok, open} = Source.load("open-survey")
    {:ok, closed} = Source.load("closed-survey")
    {:ok, _} = Surveys.save_section(open, %{login: "bo", email: nil}, "general", %{"pace" => "2"})

    assert {:error, :closed} =
             Surveys.save_section(closed, %{login: "bo", email: nil}, "general", %{})

    overview = Surveys.overview()
    assert overview.logins == ["bo"]
    assert overview.problems == []

    assert Enum.map(overview.surveys, &{&1.id, &1.responses, &1.statuses}) == [
             {"closed-survey", 0, %{}},
             {"open-survey", 1, %{"bo" => :in_progress}},
             {"quiet-survey", 0, %{}}
           ]
  end

  test "overview keeps a broken survey file as a row with its problems" do
    use_docs_files(%{"broken-survey.json" => "{nope"})
    assert %{surveys: [row]} = Surveys.overview()
    assert row.id == "broken-survey"
    assert row.definition == nil
    assert Enum.any?(row.problems, &(&1 =~ "not valid JSON"))
    assert Surveys.active() == []
  end

  test "saving a section creates one response per user, keyed by lowercased login",
       %{loaded: loaded, user: user} do
    assert {:ok, r1} =
             Surveys.save_section(loaded, user, "general", %{"one" => "Yes", "pace" => "3"})

    assert r1.github_login == "ada"
    assert r1.answers == %{"one" => "Yes", "pace" => 3}
    assert r1.answer_versions == %{"one" => 1, "pace" => 1}
    assert Map.has_key?(r1.sections_saved_at, "general")
    assert r1.survey_version == 1
    assert r1.definition_sha256 == loaded.sha256
    refute r1.saved_in_draft

    assert {:ok, r2} =
             Surveys.save_section(loaded, %{user | login: "ADA"}, "paul", %{
               "paul-excerpt" => "Too low"
             })

    assert r2.id == r1.id
    assert r2.answers == %{"one" => "Yes", "pace" => 3, "paul-excerpt" => "Too low"}
    assert [_] = Surveys.list_responses("test-survey")
    assert Surveys.get_response("test-survey", "ada").id == r1.id
  end

  test "clearing a field removes it; versions follow the survey version", %{user: user} = ctx do
    {:ok, _} = Surveys.save_section(ctx.loaded, user, "general", %{"one" => "Yes", "pace" => "3"})

    file = use_docs_dir(survey_json(%{"version" => 2}))
    assert File.exists?(file)
    {:ok, v2} = Source.load("test-survey")

    {:ok, r} = Surveys.save_section(v2, user, "general", %{"one" => "Yes", "pace" => ""})
    assert r.answers == %{"one" => "Yes"}
    assert r.answer_versions == %{"one" => 1, "pace" => 2}
    assert r.survey_version == 2

    snapshots = Surveys.list_snapshots("test-survey")
    assert Enum.map(snapshots, & &1.version) == [1, 2]
    assert Enum.all?(snapshots, &is_nil(&1.body))
    assert TalesForge.Repo.aggregate(TalesForge.Survey.Snapshot, :count) == 2
  end

  test "draft saves are marked", %{user: user} do
    use_docs_dir(survey_json(%{"status" => "draft"}))
    {:ok, draft} = Source.load("test-survey")
    {:ok, r} = Surveys.save_section(draft, user, "general", %{"one" => "No"})
    assert r.saved_in_draft
  end

  test "closed surveys refuse saves and clears", %{user: user} = ctx do
    {:ok, _} = Surveys.save_section(ctx.loaded, user, "general", %{"one" => "No"})
    use_docs_dir(survey_json(%{"status" => "closed"}))
    {:ok, closed} = Source.load("test-survey")

    assert {:error, :closed} = Surveys.save_section(closed, user, "general", %{"one" => "Yes"})
    assert {:error, :closed} = Surveys.clear_response(closed, "ada")
    assert Surveys.get_response("test-survey", "ada").answers == %{"one" => "No"}
  end

  test "unknown sections and clearing", %{loaded: loaded, user: user} do
    assert {:error, :unknown_section} = Surveys.save_section(loaded, user, "nope", %{})
    {:ok, _} = Surveys.save_section(loaded, user, "general", %{"one" => "No"})
    assert :ok = Surveys.clear_response(loaded, "Ada")
    assert Surveys.get_response("test-survey", "ada") == nil
  end

  test "current survey id defaults to the founder survey" do
    assert Surveys.current_id() == "founder-survey-3"
  end
end
