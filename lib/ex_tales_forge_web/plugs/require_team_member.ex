defmodule TalesForgeWeb.Plugs.RequireTeamMember do
  @moduledoc """
  The router's default gate (the `:browser` pipeline): lets a request through
  only for a signed-in, still active member of the ADMIN_GITHUB_TEAM GitHub team
  (`TalesForge.AdminAuth.current_email/1`) and assigns `:admin_email`. Anyone
  else is redirected to `/admin/login`; for a GET the path is remembered so the
  sign-in returns there.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller

  alias TalesForge.AdminAuth

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case AdminAuth.current_email(conn) do
      nil ->
        conn
        |> remember_path()
        |> redirect(to: "/admin/login")
        |> halt()

      email ->
        assign(conn, :admin_email, email)
    end
  end

  defp remember_path(%Plug.Conn{method: "GET"} = conn),
    do: put_session(conn, "admin_return_to", current_path(conn))

  defp remember_path(conn), do: conn
end
