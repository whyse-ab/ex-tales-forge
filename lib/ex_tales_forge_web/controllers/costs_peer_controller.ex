defmodule TalesForgeWeb.CostsPeerController do
  @moduledoc """
  `GET /internal/costs`, served by the playtest app only: its playtest-run AI
  spend as JSON for production's admin costs page
  (`TalesForge.Costs.PlaytestRuns.summary/1`: totals per line and time window
  only, no rows, prompts or player data).

  - On production or local (`TalesForge.AppRole.role/0` is not `:playtest`) it
    answers 404: production's numbers are read where they live.
  - Guarded by `COSTS_PEER_TOKEN` as a bearer token, compared in constant time.
    Token unset: 404 (the endpoint is off). Missing or wrong token: 401.
  """

  use TalesForgeWeb, :controller

  alias TalesForge.AppRole
  alias TalesForge.Costs.Peer
  alias TalesForge.Costs.PlaytestRuns

  @doc "The playtest-run summary for a caller with the shared token (see the moduledoc)."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    with :playtest <- AppRole.role(),
         expected when is_binary(expected) <- Peer.token() do
      if authorized?(conn, expected) do
        conn
        |> put_resp_header("cache-control", "no-store")
        |> json(PlaytestRuns.summary())
      else
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> put_resp_content_type("text/plain")
        |> send_resp(401, "Unauthorized")
      end
    else
      _ -> conn |> put_resp_content_type("text/plain") |> send_resp(404, "Not Found")
    end
  end

  # Hashing first makes the comparison constant-time regardless of length.
  defp authorized?(conn, expected) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> given] ->
        Plug.Crypto.secure_compare(
          :crypto.hash(:sha256, String.trim(given)),
          :crypto.hash(:sha256, expected)
        )

      _ ->
        false
    end
  end
end
