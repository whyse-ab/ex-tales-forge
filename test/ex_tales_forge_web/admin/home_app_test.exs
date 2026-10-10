defmodule TalesForgeWeb.AdminLive.HomeAppTest do
  @moduledoc false
  # Each thing lives in one place (TalesForge.AppRole): surveys on production,
  # playtest runs on playtest. Sets the global app name, so not async.
  use TalesForgeWeb.ConnCase, async: false

  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import TalesForge.SurveyFixtures

  alias TalesForge.AdminPaths
  alias TalesForge.Playtest.{Runner, Series}
  alias TalesForge.Survey.Source
  alias TalesForge.Surveys

  @prod "https://tales-forge.fly.dev"
  @playtest "https://tales-forge-playtest.fly.dev"

  @survey_paths [
    "/admin/founders/survey",
    "/admin/founders/surveys",
    "/admin/founders/surveys/founder-survey-3",
    "/admin/founders/surveys/founder-survey-3/results",
    "/admin/founders/surveys/founder-survey-3/results.csv",
    "/admin/founders/surveys/founder-survey-3/results.md"
  ]

  @run_id "761713eb-b3cd-4460-b4d0-34c7ba6f777c"
  @playtest_paths ["/admin/play/runs", "/admin/play/runs/#{@run_id}"]

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
        assert redirected_to(get(conn, path)) == @prod <> AdminPaths.legacy(path)
        # Before sign-in too: production does its own.
        assert redirected_to(get(build_conn(), path)) == @prod <> AdminPaths.legacy(path)
      end

      assert redirected_to(get(conn, "/admin/founders/surveys/founder-survey-3?x=1")) ==
               @prod <> "/admin/surveys/founder-survey-3?x=1"
    end

    test "live navigation to a survey page goes to production", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/play/sessions")

      # Another live_session: a full page load, which the plug redirects.
      assert {:error, {:redirect, %{to: "http://www.example.com/admin/founders/survey"}}} =
               live_redirect(view, to: ~p"/admin/founders/survey")

      assert redirected_to(get(conn, "/admin/founders/survey")) == @prod <> "/admin/survey"
    end

    test "playtest runs are served here and the nav links to production's survey", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/admin/play/runs")

      assert has_element?(view, ~s(#admin-nav a[href="/admin/play/runs"]), "Playtest runs")

      assert has_element?(
               view,
               ~s(#admin-nav a[href="#{@prod}/admin/survey"]),
               "Founder survey (production)"
             )

      refute has_element?(view, ~s(#admin-nav a[href="/admin/founders/survey"]))
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
        assert redirected_to(get(conn, path)) == @playtest <> AdminPaths.legacy(path)
        assert redirected_to(get(build_conn(), path)) == @playtest <> AdminPaths.legacy(path)
      end
    end

    test "the old playtest paths go straight to playtest, unchanged", %{conn: conn} do
      for path <- ["/admin/playtest", "/admin/playtest/#{@run_id}?tab=turns"] do
        assert redirected_to(get(conn, path)) == @playtest <> path
      end
    end

    test "live navigation to a playtest page goes to playtest", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/play/sessions")

      assert {:error, {:redirect, %{to: "http://www.example.com/admin/play/runs/" <> @run_id}}} =
               live_redirect(view, to: "/admin/play/runs/#{@run_id}")
    end

    test "the survey is served here and the nav links to playtest's runs", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/admin/founders/survey")

      assert html =~ "Answering as <strong>@ada</strong>"
      assert has_element?(view, ~s(#admin-nav a[href="/admin/founders/survey"]), "Founder survey")

      assert has_element?(
               view,
               ~s(#admin-nav a[href="#{@playtest}/admin/playtest"]),
               "Playtest runs (playtest)"
             )

      refute has_element?(view, ~s(#admin-nav a[href="/admin/play/runs"]))
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
      assert {:ok, _view, _html} = live(conn, ~p"/admin/founders/survey")
      assert {:ok, view, _html} = live(conn, ~p"/admin/play/runs")
      assert has_element?(view, ~s(#admin-nav a[href="/admin/founders/survey"]))
    end
  end
end
