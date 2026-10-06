defmodule TalesForgeWeb.CostsPeerController do
  @moduledoc """
  `GET /internal/costs`: this app's aggregated AI spend as JSON for the peer
  app's admin costs page (`TalesForge.Costs.ai_summary/1`: totals per bucket and
  window only, no rows, prompts or player data).

  Guarded by `COSTS_PEER_TOKEN` as a bearer token, compared in constant time.
  Token unset: the endpoint is off and answers 404. Missing or wrong token: 401.
  """

  use TalesForgeWeb, :controller

  alias TalesForge.Costs
  alias TalesForge.Costs.Peer

  def show(conn, _params) do
    case Peer.token() do
      nil ->
        conn |> put_resp_content_type("text/plain") |> send_resp(404, "Not Found")

      expected ->
        if authorized?(conn, expected) do
          conn
          |> put_resp_header("cache-control", "no-store")
          |> json(Costs.ai_summary())
        else
          conn
          |> put_resp_header("www-authenticate", "Bearer")
          |> put_resp_content_type("text/plain")
          |> send_resp(401, "Unauthorized")
        end
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
