defmodule TalesForgeWeb.CostsPeerController do
  @moduledoc """
  `GET /internal/costs`, served by the playtest app only: its playtest-run AI
  spend as JSON for production's admin costs page
  (`TalesForge.Costs.PlaytestRuns.summary/1`: totals per line and time window
  only, no rows, prompts or player data).

  - On production or local (`TalesForge.AppRole.role/1` is not `:playtest`) it
    answers 404: production's numbers are read where they live.
  - Guarded by `COSTS_PEER_TOKEN` as a bearer token, compared in constant time (`TalesForgeWeb.PeerToken`).
    Token unset: 404 (the endpoint is off). Missing or wrong token: 401.
  """

  use TalesForgeWeb, :controller

  alias TalesForge.AppRole
  alias TalesForge.Costs.PlaytestRuns
  alias TalesForgeWeb.PeerToken

  @doc "The playtest-run summary for a caller with the shared token (see the moduledoc)."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    with :playtest <- AppRole.role(),
         expected when is_binary(expected) <- AppRole.peer_token() do
      if PeerToken.authorized?(conn, expected) do
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(PlaytestRuns.summary())
      else
        PeerToken.unauthorized(conn)
      end
    else
      _ -> PeerToken.not_found(conn)
    end
  end
end
