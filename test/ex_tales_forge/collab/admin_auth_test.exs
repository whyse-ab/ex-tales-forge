defmodule TalesForge.AdminAuthTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.AdminAuth

  doctest TalesForge.AdminAuth

  test "a team member's session is valid; email is normalized" do
    put_team_membership("octo", true)

    session = %{"admin_email" => " Octo@Example.com", "admin_github_login" => "octo"}
    assert AdminAuth.current_email(session) == "octo@example.com"
  end

  test "a session for a GitHub login that isn't on the team is not valid" do
    put_team_membership("outsider", false)

    assert AdminAuth.current_email(%{
             "admin_email" => "outsider@example.com",
             "admin_github_login" => "outsider"
           }) == nil
  end

  # Magic links are gone: a cookie from an old magic-link sign-in carries only
  # the email, no GitHub login, and must not let anyone in any more.
  test "an old magic-link session (email only) cannot reach any page" do
    conn =
      build_conn()
      |> init_test_session(%{})
      |> put_session(AdminAuth.session_key(), "founder@example.com")

    for path <- [~p"/", ~p"/admin", ~p"/admin/operate/costs"] do
      assert conn |> get(path) |> redirected_to() =~ ~r{^/admin/login(\?|$)}
    end

    assert {:error, {:redirect, %{to: "/admin/login" <> _}}} = live(conn, ~p"/admin")
  end

  test "a team member reaches /admin with no second admin check" do
    conn = log_in_admin(build_conn()) |> get(~p"/admin")
    assert html_response(conn, 200) =~ "Admin home"
  end

  test "anonymous cannot reach /admin" do
    conn = get(build_conn(), ~p"/admin")
    assert redirected_to(conn) =~ ~r{^/admin/login(\?|$)}
  end

  test "clear_session drops the identity" do
    conn =
      build_conn()
      |> log_in_admin()
      |> AdminAuth.clear_session()

    assert AdminAuth.current_email(conn) == nil
  end
end
