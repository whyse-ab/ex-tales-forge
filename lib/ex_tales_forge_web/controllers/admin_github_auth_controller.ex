defmodule TalesForgeWeb.AdminGithubAuthController do
  @moduledoc """
  "Sign in with GitHub": the app's only login. Signs in active members of the
  ADMIN_GITHUB_TEAM GitHub team (`TalesForge.AdminAuth.GitHub`); anyone else is
  sent back to the login page with a short message.
  """
  use TalesForgeWeb, :controller

  require Logger

  alias TalesForge.AdminAuth
  alias TalesForge.AdminAuth.GitHub

  # CSRF state for the OAuth round trip; single use.
  @state_key "admin_github_state"

  plug :require_enabled

  @doc "Starts the OAuth flow: redirects to GitHub."
  @spec request(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def request(conn, params) do
    conn =
      case AdminAuth.safe_return_to(params["return_to"]) do
        nil -> conn
        path -> put_session(conn, "admin_return_to", path)
      end

    case GitHub.authorize_url() do
      {:ok, %{url: url, state: state}} ->
        conn
        |> put_session(@state_key, state)
        |> redirect(external: url)

      {:error, error} ->
        Logger.warning("GitHub sign-in could not start: #{inspect(error)}")
        fail(conn, "GitHub sign-in isn't working right now. Please try again.")
    end
  end

  @doc "OAuth callback: signs in a team member, refuses anyone else."
  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, params) do
    state = get_session(conn, @state_key)
    conn = delete_session(conn, @state_key)

    case GitHub.callback(params, state) do
      {:ok, %{login: login} = identity} ->
        return_to = AdminAuth.safe_return_to(get_session(conn, "admin_return_to")) || ~p"/admin"

        conn
        |> AdminAuth.put_github_session(identity)
        |> delete_session("admin_return_to")
        |> put_flash(:info, "Signed in with GitHub as @#{login}")
        |> redirect(to: return_to)

      {:error, {:not_allowed, login}} ->
        Logger.info("GitHub sign-in denied for @#{login}: not an active member of the team")

        fail(conn, "@#{login} isn't on the Tales Forge GitHub team, so you can't sign in.")

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
      |> fail("GitHub sign-in isn't set up on this server.")
      |> halt()
    end
  end
end
