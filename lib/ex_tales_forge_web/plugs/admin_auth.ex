defmodule TalesForgeWeb.Plugs.AdminAuth do
  @moduledoc """
  Requires an allowlisted admin session for /admin routes.
  Player routes never go through this plug.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller

  alias TalesForge.AdminAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    case AdminAuth.current_email(conn) do
      nil ->
        conn
        |> put_session("admin_return_to", conn.request_path)
        |> redirect(to: "/admin/login")
        |> halt()

      email ->
        assign(conn, :admin_email, email)
    end
  end
end
