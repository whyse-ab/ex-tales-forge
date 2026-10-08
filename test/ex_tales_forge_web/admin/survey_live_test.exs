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
          ~p"/admin/survey",
          ~p"/admin/surveys/founder-survey-3/results",
          ~p"/admin/surveys/founder-survey-3/results.csv",
          ~p"/admin/surveys/founder-survey-3/results.md"
        ] do
      assert redirected_to(get(conn, path)) =~ "/admin/login"
    end
  end

  test "the founder survey renders from the snapshot with who you answer as", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/survey")

    assert html =~ "Answering as <strong>@ada</strong>"
    assert html =~ "Not started"
    assert html =~ "Latest findings"
    assert html =~ "Placeholder"
    assert html =~ "What a Jev score is"
    assert html =~ "Draft."
    assert html =~ "Mute barbarian warrior"

    assert html =~
             "https://tales-forge-playtest.fly.dev/admin/playtest/761713eb-b3cd-4460-b4d0-34c7ba6f777c#turn-7"

    assert html =~ ~s(href="/admin/survey")
    refute html =~ "name?"
  end

  test "answers autosave per section and come back on reload", %{conn: conn} do
    use_docs_dir(survey_json())
    {:ok, view, _html} = live(conn, ~p"/admin/surveys/test-survey")

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

    {:ok, _view, html} = live(conn, ~p"/admin/surveys/test-survey")
    assert html =~ ~s(value="Monologues")
    assert html =~ ~r/value="Lies"\s+checked/
    assert html =~ "1 required questions left"
  end

  test "clear my answers", %{conn: conn} do
    use_docs_dir(survey_json())
    {:ok, view, _html} = live(conn, ~p"/admin/surveys/test-survey")
    view |> form("#form-general") |> render_change(%{"answers" => %{"one" => "Yes"}})

    html = view |> element("button", "Clear my answers") |> render_click()
    assert html =~ "Your answers were cleared."
    assert Surveys.get_response("test-survey", "ada") == nil
  end

  test "a closed survey is read-only", %{conn: conn} do
    use_docs_dir(survey_json(%{"status" => "closed"}))
    {:ok, view, html} = live(conn, ~p"/admin/surveys/test-survey")

    assert html =~ "Closed."
    assert html =~ "disabled"

    html = render_change(view, "save", %{"section" => "general", "answers" => %{"one" => "Yes"}})
    assert html =~ "This survey is closed; nothing was saved."
  end

  test "a bad survey file shows an admin error, not a crash", %{conn: conn} do
    use_docs_dir(~s({"format": 1, "id": "test-survey"}))
    {:ok, view, html} = live(conn, ~p"/admin/surveys/test-survey")

    assert html =~ "the survey file in tales-forge-docs has a problem"
    assert html =~ "version is missing"
    assert render_click(view, "reload") =~ "version is missing"

    {:ok, view, html} = live(conn, ~p"/admin/surveys/test-survey/results")
    assert html =~ "sections must be a non-empty list"
    assert render_click(view, "reload") =~ "has a problem"

    conn = get(conn, ~p"/admin/surveys/test-survey/results.csv")
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

    {:ok, view, html} = live(conn, ~p"/admin/surveys/test-survey/results")
    assert html =~ "Survey results"
    assert html =~ "@ada"
    assert html =~ "@bo"
    assert html =~ "“Too kind”"
    assert html =~ "“Evenings”"
    assert html =~ "Markdown summary (for personas.md)"
    assert html =~ ~s(id="results-paul")
    assert html =~ "Turn 7"

    html = view |> element("a", "@ada") |> render_click()
    assert html =~ "Answers from @ada"
    assert html =~ "Evenings"

    assert render_click(view, "reload") =~ "Survey results"

    csv = get(conn, ~p"/admin/surveys/test-survey/results.csv")
    assert csv.status == 200
    assert get_resp_header(csv, "content-type") |> hd() =~ "text/csv"
    assert csv.resp_body =~ ~s("ada","ada@example.com")
    assert csv.resp_body =~ ~s("Q8 paul-archetypes: Knight")

    md = get(conn, ~p"/admin/surveys/test-survey/results.md")
    assert md.status == 200
    assert md.resp_body =~ "## Paul"
    assert md.resp_body =~ "| Witch | 3.0 | 1 |"
  end

  test "results page for the founder survey with no answers", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/admin/surveys/founder-survey-3/results")
    assert html =~ "No answers yet."
    assert html =~ ~s(href="/admin/survey")
  end
end
