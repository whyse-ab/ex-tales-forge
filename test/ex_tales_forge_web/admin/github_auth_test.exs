defmodule TalesForgeWeb.AdminGithubAuthTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.AdminAuth.MembershipCache

  @stub TalesForge.AdminAuth.GitHub
  @team_path "/orgs/whyse-ab/teams/tales-forge/memberships/octo"

  setup do
    keys = [:github_oauth, :admin_github_team, :github_docs_token]
    saved = Map.new(keys, &{&1, Application.get_env(:ex_tales_forge, &1)})

    on_exit(fn ->
      Enum.each(saved, fn {k, v} -> Application.put_env(:ex_tales_forge, k, v) end)
      MembershipCache.clear()
    end)

    Application.put_env(:ex_tales_forge, :github_oauth,
      client_id: "cid",
      client_secret: "csecret"
    )

    Application.put_env(:ex_tales_forge, :admin_github_team, nil)
    Application.put_env(:ex_tales_forge, :github_docs_token, "server-token")
    MembershipCache.clear()
    :ok
  end

  # GitHub API stub. `emails` is the /user/emails body; `team` is the membership
  # response for octo: :active, :pending or :none.
  defp stub_github(emails, team \\ :none) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      auth = conn |> Plug.Conn.get_req_header("authorization") |> List.first()
      send(test, {:github, conn.method, conn.request_path, auth})

      case {conn.method, conn.request_path} do
        {"POST", "/login/oauth/access_token"} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/x-www-form-urlencoded")
          |> Plug.Conn.send_resp(
            200,
            "access_token=user-token&scope=read%3Aorg%2Cuser%3Aemail&token_type=bearer"
          )

        {"GET", "/user"} ->
          Req.Test.json(conn, %{"id" => 1, "login" => "octo", "name" => "Octo Cat"})

        {"GET", "/user/emails"} ->
          Req.Test.json(conn, emails)

        {"GET", @team_path} ->
          case team do
            :active ->
              Req.Test.json(conn, %{"state" => "active", "role" => "member"})

            :pending ->
              Req.Test.json(conn, %{"state" => "pending", "role" => "member"})

            :none ->
              conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
          end
      end
    end)
  end

  defp email(address, opts \\ []) do
    %{
      "email" => address,
      "verified" => Keyword.get(opts, :verified, true),
      "primary" => Keyword.get(opts, :primary, false)
    }
  end

  # Runs the OAuth round trip; returns the conn after the callback.
  defp sign_in(state_override \\ nil) do
    conn = get(build_conn(), ~p"/admin/auth/github")
    location = redirected_to(conn, 302)
    %URI{host: "github.com", path: "/login/oauth/authorize", query: query} = URI.parse(location)
    params = URI.decode_query(query)

    assert params["scope"] == "read:org user:email"
    assert params["client_id"] == "cid"
    assert params["redirect_uri"] == TalesForgeWeb.Endpoint.url() <> "/admin/auth/github/callback"

    state = state_override || params["state"]
    conn |> recycle() |> get(~p"/admin/auth/github/callback?#{[code: "abc", state: state]}")
  end

  defp signed_in?(conn) do
    case conn |> recycle() |> get(~p"/admin") do
      %{status: 200} -> true
      %{status: 302} -> false
    end
  end

  test "allowlisted verified email (not the primary) signs in" do
    stub_github([
      email("octo@personal.example", primary: true),
      email("FOUNDER@example.com")
    ])

    conn = sign_in()

    assert redirected_to(conn) == "/admin"
    assert get_session(conn, "admin_email") == "founder@example.com"
    assert get_session(conn, "admin_github_login") == "octo"
    assert get_session(conn, "admin_github_state") == nil
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "@octo"
    assert signed_in?(conn)
    # The user's token was used for GitHub's user API, and never stored.
    assert_received {:github, "GET", "/user/emails", "Bearer user-token"}
    refute inspect(get_session(conn)) =~ "user-token"
  end

  test "an allowlisted but unverified email is denied" do
    stub_github([
      email("octo@personal.example", primary: true),
      email("founder@example.com", verified: false)
    ])

    conn = sign_in()

    assert redirected_to(conn) == "/admin/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "@octo isn't allowed"
    assert get_session(conn, "admin_email") == nil

    # The login page must actually show the reason, not swallow it.
    {:ok, _view, html} = live(recycle(conn), ~p"/admin/login")
    assert html =~ "@octo isn&#39;t allowed"
    refute signed_in?(conn)
  end

  test "active team member signs in when ADMIN_GITHUB_TEAM is set" do
    Application.put_env(:ex_tales_forge, :admin_github_team, "whyse-ab/tales-forge")
    stub_github([email("octo@personal.example", primary: true)], :active)

    conn = sign_in()

    assert redirected_to(conn) == "/admin"
    assert get_session(conn, "admin_email") == "octo@personal.example"
    assert get_session(conn, "admin_github_login") == "octo"
    assert signed_in?(conn)
    # Membership is checked with the server token, not the user's.
    assert_received {:github, "GET", @team_path, "Bearer server-token"}
  end

  test "a pending team invite is denied" do
    Application.put_env(:ex_tales_forge, :admin_github_team, "whyse-ab/tales-forge")
    stub_github([email("octo@personal.example", primary: true)], :pending)

    conn = sign_in()

    assert redirected_to(conn) == "/admin/login"
    assert get_session(conn, "admin_email") == nil
    refute signed_in?(conn)
  end

  test "team membership doesn't count when ADMIN_GITHUB_TEAM is unset" do
    stub_github([email("octo@personal.example", primary: true)], :active)

    conn = sign_in()

    assert redirected_to(conn) == "/admin/login"
    assert get_session(conn, "admin_email") == nil
    refute_received {:github, "GET", @team_path, _}
  end

  test "a bad state is denied before any token exchange" do
    stub_github([email("founder@example.com", primary: true)])

    conn = sign_in("forged-state")

    assert redirected_to(conn) == "/admin/login"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "didn't complete"
    assert get_session(conn, "admin_email") == nil
    refute_received {:github, "POST", "/login/oauth/access_token", _}
  end

  test "a callback without a started flow is denied" do
    stub_github([email("founder@example.com", primary: true)])

    conn = get(build_conn(), ~p"/admin/auth/github/callback?code=abc&state=whatever")

    assert redirected_to(conn) == "/admin/login"
    assert get_session(conn, "admin_email") == nil
    refute_received {:github, _, _, _}
  end

  test "losing team membership revokes the session once the cache expires" do
    Application.put_env(:ex_tales_forge, :admin_github_team, "whyse-ab/tales-forge")
    stub_github([email("octo@personal.example", primary: true)], :active)
    conn = sign_in()
    assert signed_in?(conn)

    # Removed from the team: the cached "active" still holds for the window...
    stub_github([email("octo@personal.example", primary: true)], :none)
    assert signed_in?(conn)

    # ...and once it expires, both the plug and the LiveView mount refuse.
    MembershipCache.clear()
    refute signed_in?(conn)
    assert {:error, {:redirect, %{to: "/admin/login"}}} = live(recycle(conn), ~p"/admin")
  end

  test "unsetting ADMIN_GITHUB_TEAM revokes team sessions immediately" do
    Application.put_env(:ex_tales_forge, :admin_github_team, "whyse-ab/tales-forge")
    stub_github([email("octo@personal.example", primary: true)], :active)
    conn = sign_in()
    assert signed_in?(conn)

    Application.put_env(:ex_tales_forge, :admin_github_team, nil)
    refute signed_in?(conn)
  end

  test "removing the email from ADMIN_EMAILS revokes an email-matched GitHub session" do
    stub_github([email("founder@example.com", primary: true)])
    conn = sign_in()
    assert signed_in?(conn)

    original = Application.get_env(:ex_tales_forge, :admin_emails)
    on_exit(fn -> Application.put_env(:ex_tales_forge, :admin_emails, original) end)
    Application.put_env(:ex_tales_forge, :admin_emails, ["other@example.com"])

    refute signed_in?(conn)
  end

  test "logout clears the GitHub keys" do
    stub_github([email("founder@example.com", primary: true)])
    conn = sign_in()

    conn = conn |> recycle() |> delete(~p"/admin/logout")

    assert get_session(conn, "admin_email") == nil
    assert get_session(conn, "admin_github_login") == nil
    refute signed_in?(conn)
  end

  test "login page shows the GitHub button only when a client id and secret are set" do
    assert get(build_conn(), ~p"/admin/login") |> html_response(200) =~ ~s(id="github-login")

    Application.put_env(:ex_tales_forge, :github_oauth, client_id: nil, client_secret: "csecret")
    html = get(build_conn(), ~p"/admin/login") |> html_response(200)
    refute html =~ "github-login"
    refute html =~ "Sign in with GitHub"
    assert html =~ "Send magic link"
  end

  test "GitHub routes redirect with a flash when not configured" do
    Application.put_env(:ex_tales_forge, :github_oauth, client_id: "cid", client_secret: "")

    for path <- [~p"/admin/auth/github", ~p"/admin/auth/github/callback?code=x&state=y"] do
      conn = get(build_conn(), path)
      assert redirected_to(conn) == "/admin/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "isn't set up"
    end
  end
end
