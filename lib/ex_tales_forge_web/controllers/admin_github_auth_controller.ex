defmodule TalesForgeWeb.AdminGithubAuthController do
  @moduledoc "Sign in with GitHub for /admin. Email magic links stay as the fallback."
  use TalesForgeWeb, :controller

  require Logger

  alias TalesForge.AdminAuth
  alias TalesForge.AdminAuth.GitHub

  # CSRF state for the OAuth round trip; single use.
  @state_key "admin_github_state"

  plug :require_enabled

  def request(conn, _params) do
    case GitHub.authorize_url() do
      {:ok, %{url: url, state: state}} ->
        conn
        |> put_session(@state_key, state)
        |> redirect(external: url)

      {:error, error} ->
        Logger.warning("GitHub sign-in could not start: #{inspect(error)}")
        fail(conn, "GitHub sign-in isn't working right now. Use an email link instead.")
    end
  end

  def callback(conn, params) do
    state = get_session(conn, @state_key)
    conn = delete_session(conn, @state_key)

    case GitHub.callback(params, state) do
      {:ok, %{login: login} = identity} ->
        return_to = get_session(conn, "admin_return_to") || ~p"/admin"

        conn
        |> AdminAuth.put_github_session(identity)
        |> delete_session("admin_return_to")
        |> put_flash(:info, "Signed in with GitHub as @#{login}")
        |> redirect(to: return_to)

      {:error, {:not_allowed, login}} ->
        fail(
          conn,
          "@#{login} isn't allowed into the admin. Ask Fredrik for access, or use an email link."
        )

      {:error, error} ->
        Logger.info("GitHub sign-in failed: #{inspect(error)}")
        fail(conn, "GitHub sign-in didn't complete. Please try again.")
    end
  end

  defp fail(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/admin/login")
  end

  defp require_enabled(conn, _opts) do
    if GitHub.enabled?() do
      conn
    else
      conn
      |> fail("GitHub sign-in isn't set up. Use an email link instead.")
      |> halt()
    end
  end
end
