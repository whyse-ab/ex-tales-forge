defmodule TalesForgeWeb.AdminLive.HomeAppTest do
  @moduledoc false
  # Each thing lives in one place (TalesForge.AppRole): surveys on production,
  # playtest runs on playtest. Sets the global app name, so not async.
  use TalesForgeWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import TalesForge.SurveyFixtures

  alias TalesForge.Playtest.{Runner, Series}
  alias TalesForge.Survey.Source
  alias TalesForge.Surveys

  @prod "https://tales-forge.fly.dev"
  @playtest "https://tales-forge-playtest.fly.dev"

  @survey_paths [
    "/admin/survey",
    "/admin/surveys",
    "/admin/surveys/founder-survey-3",
    "/admin/surveys/founder-survey-3/results",
    "/admin/surveys/founder-survey-3/results.csv",
    "/admin/surveys/founder-survey-3/results.md"
  ]

  @run_id "761713eb-b3cd-4460-b4d0-34c7ba6f777c"
  @playtest_paths ["/admin/playtest", "/admin/playtest/#{@run_id}"]

  setup %{conn: conn} do
    snapshot_only()

    on_exit(fn ->
      Application.delete_env(:ex_tales_forge, :app_name)
      Application.delete_env(:ex_tales_forge, :playtest_runner_enabled)
    end)

    {:ok, conn: log_in_admin(conn, "ada@example.com", login: "ada")}
  end

  defp as_app(name), do: Application.put_env(:ex_tales_forge, :app_name, name)

  describe "on playtest" do
    setup do: as_app("tales-forge-playtest")

    test "survey pages and downloads redirect to the same path on production", %{conn: conn} do
      for path <- @survey_paths do
        assert redirected_to(get(conn, path)) == @prod <> path
        # Before sign-in too: production does its own.
        assert redirected_to(get(build_conn(), path)) == @prod <> path
      end

      assert redirected_to(get(conn, "/admin/surveys/founder-survey-3?x=1")) ==
               @prod <> "/admin/surveys/founder-survey-3?x=1"
    end

    test "live navigation to a survey page goes to production", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/sessions")

      # Another live_session: a full page load, which the plug redirects.
      assert {:error, {:redirect, %{to: "http://www.example.com/admin/survey"}}} =
               live_redirect(view, to: ~p"/admin/survey")

      assert redirected_to(get(conn, "/admin/survey")) == @prod <> "/admin/survey"
    end

    test "playtest runs are served here and the nav links to production's survey", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/playtest")

      assert has_element?(view, ~s(#admin-nav a[href="/admin/playtest"]), "Playtest runs")

      assert has_element?(
               view,
               ~s(#admin-nav a[href="#{@prod}/admin/survey"]),
               "Founder survey (production)"
             )

      refute has_element?(view, ~s(#admin-nav a[href="/admin/survey"]))
    end

    test "survey answers can't be saved or cleared" do
      use_docs_dir(survey_json())
      {:ok, loaded} = Source.load("test-survey")
      user = %{login: "ada", email: "ada@example.com"}

      assert Surveys.save_section(loaded, user, "general", %{"one" => "Yes"}) ==
               {:error, :wrong_app}

      assert Surveys.get_response("test-survey", "ada") == nil
      assert Surveys.clear_response(loaded, "ada") == {:error, :wrong_app}
    end

    test "persona runs may start" do
      Application.put_env(:ex_tales_forge, :playtest_runner_enabled, true)
      assert Runner.enabled?()
    end
  end

  describe "on production" do
    setup do: as_app("tales-forge")

    test "playtest run pages redirect to the same path on playtest", %{conn: conn} do
      for path <- @playtest_paths do
        assert redirected_to(get(conn, path)) == @playtest <> path
        assert redirected_to(get(build_conn(), path)) == @playtest <> path
      end
    end

    test "live navigation to a playtest page goes to playtest", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/sessions")

      assert {:error, {:redirect, %{to: "http://www.example.com/admin/playtest/" <> @run_id}}} =
               live_redirect(view, to: "/admin/playtest/#{@run_id}")
    end

    test "the survey is served here and the nav links to playtest's runs", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/survey")

      assert html =~ "Answering as <strong>@ada</strong>"
      assert has_element?(view, ~s(#admin-nav a[href="/admin/survey"]), "Founder survey")

      assert has_element?(
               view,
               ~s(#admin-nav a[href="#{@playtest}/admin/playtest"]),
               "Playtest runs (playtest)"
             )

      refute has_element?(view, ~s(#admin-nav a[href="/admin/playtest"]))
    end

    test "survey answers save" do
      use_docs_dir(survey_json())
      {:ok, loaded} = Source.load("test-survey")
      user = %{login: "ada", email: "ada@example.com"}

      assert {:ok, _} = Surveys.save_section(loaded, user, "general", %{"one" => "Yes"})
    end

    test "persona runs and series refuse to start, even with the runner flag on" do
      Application.put_env(:ex_tales_forge, :playtest_runner_enabled, true)

      refute Runner.enabled?()
      assert Runner.start("paul", "tin_valley", turn_limit: 1) == {:error, :disabled}

      assert Series.start("s", personas: ["paul"], variants: ["default"], runs: 1) ==
               {:error, :disabled}
    end
  end

  describe "locally (no app name)" do
    test "both live here", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, ~p"/admin/survey")
      assert {:ok, view, _html} = live(conn, ~p"/admin/playtest")
      assert has_element?(view, ~s(#admin-nav a[href="/admin/survey"]))
    end
  end
end
