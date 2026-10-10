defmodule TalesForgeWeb.Plugs.HomeApp do
  @moduledoc """
  Sends requests for pages that live on the other app there
  (`TalesForge.AppRole.redirect_url/3`): on playtest, `/admin/survey`,
  `/admin/surveys` and everything below them (including the result
  downloads), `/team` and `/team/presentation`, the founders' decisions and
  the docs redirect to the same path on production; on production,
  `/admin/playtest` and below redirect to playtest. The query string is kept.
  Runs before the sign-in check, so the other app does its own sign-in.
  Those pages have their own live_sessions in the router, so reaching them
  from another admin page is a full page load through this plug too.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias TalesForge.AppRole

  @impl Plug
  @spec init(term()) :: term()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case AppRole.redirect_url(conn.request_path, conn.query_string) do
      nil -> conn
      url -> conn |> redirect(external: url) |> halt()
    end
  end
end
