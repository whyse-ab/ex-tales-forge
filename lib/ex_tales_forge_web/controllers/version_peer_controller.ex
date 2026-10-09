defmodule TalesForgeWeb.VersionPeerController do
  @moduledoc """
  `GET /internal/version`, on both apps: the commit this app runs, as JSON
  `{"app": "production" | "playtest" | "local", "git_sha": "..." | null}`, so
  the other app's live PR feed on `/team` can tell which merged pull requests
  are deployed here (`TalesForge.PrFeed.Versions`). No other data.

  Guarded like `/internal/costs` by the shared `COSTS_PEER_TOKEN` as a bearer
  token (`TalesForgeWeb.PeerToken`): token unset, 404 (the endpoint is off);
  missing or wrong token, 401. Never calls an LLM or the database.
  """

  use TalesForgeWeb, :controller

  alias TalesForge.AppRole
  alias TalesForge.Costs.Peer
  alias TalesForge.Playtest.RunMeta
  alias TalesForgeWeb.PeerToken

  @doc "This app's role and running commit for a caller with the shared token."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    case Peer.token() do
      nil ->
        PeerToken.not_found(conn)

      expected ->
        if PeerToken.authorized?(conn, expected) do
          conn
          |> put_resp_header("cache-control", "no-store")
          |> json(%{app: Atom.to_string(AppRole.role()), git_sha: RunMeta.git_sha()})
        else
          PeerToken.unauthorized(conn)
        end
    end
  end
end
