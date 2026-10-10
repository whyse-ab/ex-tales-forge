defmodule TalesForgeWeb.OnlinePeerController do
  @moduledoc """
  `GET /internal/online`, served by the playtest app only: the founders with a
  page open on playtest right now (`TalesForge.Online.local/0`: email, page
  name, app, since), as JSON `{"founders": [...]}`, for "Online now" on
  production's `/team` (`TalesForge.Online.Peer`).

  Guarded like `/internal/costs` by the shared `COSTS_PEER_TOKEN` as a bearer
  token (`TalesForgeWeb.PeerToken`). On production or local, or with the token
  unset: 404. Missing or wrong token: 401.
  """

  use TalesForgeWeb, :controller

  alias TalesForge.AppRole
  alias TalesForge.Online
  alias TalesForgeWeb.PeerToken

  @doc "Playtest's founders online, for a caller with the shared token."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    with :playtest <- AppRole.role(),
         expected when is_binary(expected) <- AppRole.peer_token() do
      if PeerToken.authorized?(conn, expected) do
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(%{founders: Online.local()})
      else
        PeerToken.unauthorized(conn)
      end
    else
      _ -> PeerToken.not_found(conn)
    end
  end
end
