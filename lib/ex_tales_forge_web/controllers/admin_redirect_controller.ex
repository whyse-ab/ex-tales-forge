defmodule TalesForgeWeb.AdminRedirectController do
  @moduledoc """
  Keeps the admin URLs from before the 2026-10-10 regrouping working:
  `GET /admin/<old>` and everything below it redirect to the page's path now
  (`TalesForge.AdminPaths.canonical/1`), with the query string. A temporary
  redirect (302), so a revert of the regrouping can't leave browsers stuck on
  a cached permanent one.
  """

  use TalesForgeWeb, :controller

  alias TalesForge.AdminPaths

  @doc """
  Redirects a section root (`/admin/play`, `/admin/founders`, ...) to that
  section on the admin home (`/admin#section-play`). The query is kept
  before the anchor.
  """
  @spec section(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def section(conn, _params) do
    "/admin#" <> anchor = AdminPaths.section_target(conn.request_path)
    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
    redirect(conn, to: "/admin" <> query <> "#" <> anchor)
  end

  @doc "Redirects an old admin path to its new one."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    path = AdminPaths.canonical(conn.request_path)
    to = if conn.query_string == "", do: path, else: path <> "?" <> conn.query_string
    redirect(conn, to: to)
  end
end
