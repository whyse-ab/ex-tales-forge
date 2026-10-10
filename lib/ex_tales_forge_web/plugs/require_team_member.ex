defmodule TalesForgeWeb.Plugs.RequireTeamMember do
  @moduledoc """
  The router's default gate (the `:browser` pipeline): lets a request through
  only for a signed-in, still active member of the ADMIN_GITHUB_TEAM GitHub team
  (`TalesForge.AdminAuth.current_email/1`) and assigns `:admin_email`. Anyone
  else is redirected to `/admin/login`; for a GET the path and query are
  remembered (in the session and as `?return_to=`, same-origin only,
  `TalesForge.AdminAuth.safe_return_to/1`) so the sign-in returns there.
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
        |> redirect(to: login_path(conn))
        |> halt()

      email ->
        assign(conn, :admin_email, email)
    end
  end

  defp remember_path(%Plug.Conn{method: "GET"} = conn),
    do: put_session(conn, "admin_return_to", current_path(conn))

  defp remember_path(conn), do: conn

  @doc """
  The login URL that returns to the requested page (path and query) after
  sign-in, for a GET; plain `/admin/login` otherwise.
  """
  @spec login_path(Plug.Conn.t()) :: String.t()
  def login_path(%Plug.Conn{method: "GET"} = conn) do
    case AdminAuth.safe_return_to(current_path(conn)) do
      nil -> "/admin/login"
      path -> "/admin/login?" <> URI.encode_query(%{"return_to" => path})
    end
  end

  def login_path(_conn), do: "/admin/login"
end
