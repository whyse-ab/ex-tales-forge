defmodule TalesForgeWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use TalesForgeWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint TalesForgeWeb.Endpoint

      use TalesForgeWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import TalesForgeWeb.ConnCase
    end
  end

  setup tags do
    TalesForge.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Signs the conn in as a GitHub team member, the app's only kind of user: puts
  the email and GitHub login in the session and caches an active membership of
  the test team (config/test.exs ADMIN_GITHUB_TEAM) for that login, so no
  GitHub call is made. Options: `:login` (default "tf-tester").
  """
  def log_in_admin(conn, email \\ "founder@example.com", opts \\ []) do
    login = Keyword.get(opts, :login, "tf-tester")
    put_team_membership(login, true)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(TalesForge.AdminAuth.session_key(), String.downcase(email))
    |> Plug.Conn.put_session(TalesForge.AdminAuth.github_login_key(), login)
  end

  @doc """
  Signs the conn in as a GitHub user who is NOT an active team member (a valid
  looking session that must be refused everywhere).
  """
  def log_in_non_member(conn, login \\ "outsider") do
    put_team_membership(login, false)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(TalesForge.AdminAuth.session_key(), "#{login}@example.com")
    |> Plug.Conn.put_session(TalesForge.AdminAuth.github_login_key(), login)
  end

  @doc "Caches `login`'s membership of the configured test team as `member?`."
  def put_team_membership(login, member?) do
    {org, slug} = TalesForge.AdminAuth.GitHub.team()

    TalesForge.AdminAuth.MembershipCache.put(
      {String.downcase(org), String.downcase(slug), String.downcase(login)},
      member?,
      :timer.hours(1)
    )
  end
end
