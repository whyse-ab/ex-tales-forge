defmodule TalesForgeWeb.AdminSessionController do
  @moduledoc """
  Logout. Sign-in is GitHub only (`TalesForgeWeb.AdminGithubAuthController`);
  email magic links were removed on 2026-10-07.
  """

  use TalesForgeWeb, :controller

  alias TalesForge.AdminAuth

  @doc "Signs out and returns to the login page."
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> AdminAuth.clear_session()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/admin/login")
  end
end
