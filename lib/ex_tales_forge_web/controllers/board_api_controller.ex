defmodule TalesForgeWeb.BoardApiController do
  @moduledoc """
  The bots' API for the founders' idea board, `/internal/board/*` (router):
  list and read cards, write Case's refinement, move a card, add a link (PR,
  playtest) and comment. JSON in and out.

  - Production only, like the board (`TalesForge.AppRole.here?(:board)`):
    elsewhere 404.
  - Off (404) until the board module is deployed (`TalesForge.BoardApi.impl/0`).
  - Each bot has its own bearer token (`TalesForge.BoardApi.bot_for_token/1`);
    missing or unknown: 401. Who may do what is checked by the board itself.
  """

  use TalesForgeWeb, :controller

  alias TalesForge.AppRole
  alias TalesForge.BoardApi
  alias TalesForgeWeb.PeerToken

  for action <- [:index, :show, :refine, :move, :link, :comment, :pr] do
    @doc "`#{action}` for an authorised bot (see the moduledoc)."
    @spec unquote(action)(Plug.Conn.t(), map()) :: Plug.Conn.t()
    def unquote(action)(conn, params), do: dispatch(conn, unquote(action), params)
  end

  defp dispatch(conn, action, params) do
    with true <- AppRole.here?(:board),
         mod when not is_nil(mod) <- BoardApi.impl() do
      case conn |> bearer() |> BoardApi.bot_for_token() do
        nil ->
          PeerToken.unauthorized(conn)

        bot ->
          {status, body} = mod.handle(action, bot, params)

          conn
          |> put_resp_header("cache-control", "no-store")
          |> put_status(status)
          |> json(body)
      end
    else
      _ -> PeerToken.not_found(conn)
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end
end
