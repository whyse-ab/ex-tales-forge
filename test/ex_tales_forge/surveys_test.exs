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
