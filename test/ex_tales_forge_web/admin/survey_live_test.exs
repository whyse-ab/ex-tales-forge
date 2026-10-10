defmodule TalesForgeWeb.AdminLive.SurveyLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import TalesForge.SurveyFixtures

  alias TalesForge.Surveys

  setup %{conn: conn} do
    snapshot_only()
    {:ok, conn: log_in_admin(conn, "ada@example.com", login: "ada")}
  end

  test "survey, results and exports are team-only" do
    for conn <- [build_conn(), log_in_non_member(build_conn())],
        path <- [
          ~p"/admin/founders/survey",
          ~p"/admin/founders/surveys",
          ~p"/admin/founders/surveys/founder-survey-3/results",
          ~p"/admin/founders/surveys/founder-survey-3/results.csv",
          ~p"/admin/founders/surveys/founder-survey-3/results.md"
        ] do
      assert redirected_to(get(conn, path)) =~ "/admin/login"
    end
  end

  test "the founder survey renders from the snapshot with who you answer as", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/founders/survey")

    assert html =~ "Answering as <strong>@ada</strong>"
    assert html =~ "Not started"
    assert html =~ "Latest findings"
    assert html =~ "leaving the inn now works"
    assert html =~ "What a Jev score is"
    refute html =~ "Draft."
    assert html =~ "Mute barbarian warrior"

    assert html =~
             "https://tales-forge-playtest.fly.dev/admin/playtest/761713eb-b3cd-4460-b4d0-34c7ba6f777c#turn-7"

    assert html =~ ~s(href="/admin/founders/survey")
    refute html =~ "name?"
  end

  test "answers autosave per section and come back on reload", %{conn: conn} do
    use_docs_dir(survey_json())
    {:ok, view, _html} = live(conn, ~p"/admin/founders/surveys/test-survey")

    html =
      view
      |> form("#form-paul")
      |> render_change(%{
        "answers" => %{
          "paul-keywords" => ["", "Lies"],
          "paul-keywords.other" => "Monologues",
          "paul-excerpt" => "About right",
          "paul-archetypes" => %{"0" => "3 Love"}
        }
      })

    assert html =~ "Saved"
    assert html =~ "3/8 answered"

    response = Surveys.get_response("test-survey", "ada")
    assert response.email == "ada@example.com"
    assert response.answers["paul-archetypes"] == %{"Knight" => "3 Love"}
    assert response.saved_in_draft == false

    {:ok, _view, html} = live(conn, ~p"/admin/founders/surveys/test-survey")
    assert html =~ ~s(value="Monologues")
    assert html =~ ~r/value="Lies"\s+checked/
    assert html =~ "1 required questions left"
  end

  test "clear my answers", %{conn: conn} do
    use_docs_dir(survey_json())
    {:ok, view, _html} = live(conn, ~p"/admin/founders/surveys/test-survey")
    view |> form("#form-general") |> render_change(%{"answers" => %{"one" => "Yes"}})

    html = view |> element("button", "Clear my answers") |> render_click()
    assert html =~ "Your answers were cleared."
    assert Surveys.get_response("test-survey", "ada") == nil
  end

  test "a closed survey is read-only", %{conn: conn} do
    use_docs_dir(survey_json(%{"status" => "closed"}))
    {:ok, view, html} = live(conn, ~p"/admin/founders/surveys/test-survey")

    assert html =~ "Closed."
    assert html =~ "disabled"

    html = render_change(view, "save", %{"section" => "general", "answers" => %{"one" => "Yes"}})
    assert html =~ "This survey is closed; nothing was saved."
  end

  test "a bad survey file shows an admin error, not a crash", %{conn: conn} do
    use_docs_dir(~s({"format": 1, "id": "test-survey"}))
    {:ok, view, html} = live(conn, ~p"/admin/founders/surveys/test-survey")

    assert html =~ "the survey file in tales-forge-docs has a problem"
    assert html =~ "version is missing"
    assert render_click(view, "reload") =~ "version is missing"

    {:ok, view, html} = live(conn, ~p"/admin/founders/surveys/test-survey/results")
    assert html =~ "sections must be a non-empty list"
    assert render_click(view, "reload") =~ "has a problem"

    conn = get(conn, ~p"/admin/founders/surveys/test-survey/results.csv")
    assert conn.status == 404
  end

  test "results: completion, per-user answers, aggregates and exports", %{conn: conn} do
    use_docs_dir(survey_json())
    {:ok, loaded} = TalesForge.Survey.Source.load("test-survey")

    {:ok, _} =
      Surveys.save_section(loaded, %{login: "ada", email: "ada@example.com"}, "general", %{
        "one" => "Yes",
        "week" => "Evenings"
      })

    {:ok, _} =
      Surveys.save_section(loaded, %{login: "bo", email: nil}, "paul", %{
        "paul-excerpt" => "Too high",
        "paul-excerpt.why" => "Too kind",
        "paul-archetypes" => %{"0" => "2", "1" => "3 Love"}
      })

    {:ok, view, html} = live(conn, ~p"/admin/founders/surveys/test-survey/results")
    assert html =~ "Survey results"
    assert html =~ "@ada"
    assert html =~ "@bo"
    assert html =~ "“Too kind”"
    assert html =~ "“Evenings”"
    assert html =~ "Markdown summary (for personas.md)"
    assert html =~ ~s(id="results-paul")
    assert html =~ "Turn 7"
    assert html =~ "later: none · reading: one"

    html = view |> element("a", "@ada") |> render_click()
    assert html =~ "Answers from @ada"
    assert html =~ "Evenings"

    assert render_click(view, "reload") =~ "Survey results"

    csv = get(conn, ~p"/admin/founders/surveys/test-survey/results.csv")
    assert csv.status == 200
    assert get_resp_header(csv, "content-type") |> hd() =~ "text/csv"
    assert csv.resp_body =~ ~s("ada","ada@example.com")
    assert csv.resp_body =~ ~s("Q8 paul-archetypes: Knight")
    assert csv.resp_body =~ ~s("Q1 one: labels")

    md = get(conn, ~p"/admin/founders/surveys/test-survey/results.md")
    assert md.status == 200
    assert md.resp_body =~ "## Paul"
    assert md.resp_body =~ "| Witch | 3.0 | 1 |"
    assert md.resp_body =~ "- Yes: 1 — `later: none · reading: one`"
  end

  test "results page for the founder survey with no answers", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/founders/surveys/founder-survey-3/results")
    assert html =~ "No answers yet."
    assert html =~ ~s(href="/admin/founders/surveys/founder-survey-3")
    assert html =~ "an open tab"
  end

  test "the snapshots give two tabs: founder survey 3, then the intent survey", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/founders/survey")

    assert html =~ ~s(id="survey-tabs")
    assert html =~ "Play style &amp; scores"
    assert html =~ "What did the player mean?"
    assert length(Regex.scan(~r/id="survey-tab-/, html)) == 2
    assert view |> element("#survey-tab-founder-survey-3[aria-current=page]") |> has_element?()

    {:ok, view, html} = live(conn, ~p"/admin/founders/surveys/founder-survey-4-intent")

    assert view
           |> element("#survey-tab-founder-survey-4-intent[aria-current=page]")
           |> has_element?()

    assert html =~ "The player types:"
    refute html =~ "survey-inactive"
  end

  test "tabs show only active, open surveys with this founder's status", %{conn: conn} do
    three_surveys()
    {:ok, open} = TalesForge.Survey.Source.load("open-survey")

    {:ok, view, html} = live(conn, ~p"/admin/founders/survey")
    assert html =~ "Open one"
    refute html =~ "survey-tab-quiet-survey"
    refute html =~ "survey-tab-closed-survey"
    assert view |> element("#survey-tab-open-survey [data-status=not_started]") |> has_element?()

    view
    |> form("#form-general", %{"section" => "general", "answers" => %{"pace" => "4"}})
    |> render_change()

    assert view |> element("#survey-tab-open-survey [data-status=in_progress]") |> has_element?()

    {:ok, _} =
      Surveys.save_section(open, %{login: "ada", email: nil}, "paul", %{
        "paul-excerpt" => "Too low"
      })

    {:ok, _} =
      Surveys.save_section(open, %{login: "ada", email: nil}, "general", %{"one" => "Yes"})

    {:ok, view, _html} = live(conn, ~p"/admin/founders/survey")
    assert view |> element("#survey-tab-open-survey [data-status=done]") |> has_element?()

    render_click(view, "clear")
    assert view |> element("#survey-tab-open-survey [data-status=not_started]") |> has_element?()
    assert render_click(view, "reload") =~ "Open one"
  end

  test "an inactive or closed survey is still readable, with its results", %{conn: conn} do
    three_surveys()

    {:ok, _view, html} = live(conn, ~p"/admin/founders/surveys/quiet-survey")
    assert html =~ "Quiet survey"
    assert html =~ ~s(id="survey-inactive")
    assert html =~ "survey-tab-open-survey"

    {:ok, _view, html} = live(conn, ~p"/admin/founders/surveys/closed-survey/results")
    assert html =~ "Closed survey"
    assert html =~ "not an open tab"
    assert get(conn, ~p"/admin/founders/surveys/closed-survey/results.csv").status == 200
  end

  test "with no active survey the page falls back to the configured one", %{conn: conn} do
    use_docs_files(%{"quiet-survey.json" => survey_json(%{"id" => "quiet-survey"})})
    {:ok, _view, html} = live(conn, ~p"/admin/founders/survey")
    refute html =~ ~s(id="survey-tabs")
    assert html =~ "survey-problems"
  end

  test "all surveys: every file with each founder's status", %{conn: conn} do
    three_surveys()
    {:ok, open} = TalesForge.Survey.Source.load("open-survey")
    {:ok, _} = Surveys.save_section(open, %{login: "bo", email: nil}, "general", %{"pace" => "2"})

    {:ok, view, html} = live(conn, ~p"/admin/founders/surveys")
    assert html =~ "Founder surveys"
    assert html =~ "@bo"

    assert view |> element("#survey-row-open-survey", "Open tab") |> has_element?()
    assert view |> element("#survey-row-quiet-survey", "Not a tab") |> has_element?()
    assert view |> element("#survey-row-closed-survey", "Closed") |> has_element?()
    assert view |> element("#survey-row-open-survey [data-status=in_progress]") |> has_element?()

    assert view
           |> element("#survey-row-closed-survey [data-status=not_started]")
           |> has_element?()

    assert html =~ ~s(href="/admin/founders/surveys/closed-survey/results.csv")
    assert render_click(view, "reload") =~ "Founder surveys"
  end

  test "all surveys lists a broken file as failed to load", %{conn: conn} do
    use_docs_files(%{"broken-survey.json" => "{nope"})
    {:ok, _view, html} = live(conn, ~p"/admin/founders/surveys")
    assert html =~ "Failed to load"
  end
end
