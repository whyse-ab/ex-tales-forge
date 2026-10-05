defmodule TalesForgeWeb.Plugs.AdminEmail do
  @moduledoc """
  Puts allowlisted admin email into conn assigns when present (no redirect).
  Used on the public login routes inside /admin.
  """

  @behaviour Plug

  import Plug.Conn

  alias TalesForge.AdminAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    assign(conn, :admin_email, AdminAuth.current_email(conn))
  end
end
