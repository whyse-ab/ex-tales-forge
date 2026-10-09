defmodule TalesForgeWeb.PeerToken do
  @moduledoc """
  The bearer-token check of the machine-to-machine `/internal/*` endpoints
  (`TalesForgeWeb.CostsPeerController`, `TalesForgeWeb.VersionPeerController`):
  the shared `COSTS_PEER_TOKEN`, compared in constant time.
  """

  import Plug.Conn

  @doc """
  True when the request's `Authorization: Bearer ...` equals `expected`.
  Hashing first makes the comparison constant-time regardless of length.
  """
  @spec authorized?(Plug.Conn.t(), String.t()) :: boolean()
  def authorized?(conn, expected) do
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

  @doc "Answers 401 with a `WWW-Authenticate: Bearer` header."
  @spec unauthorized(Plug.Conn.t()) :: Plug.Conn.t()
  def unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_resp_content_type("text/plain")
    |> send_resp(401, "Unauthorized")
  end

  @doc "Answers 404 (the endpoint is off)."
  @spec not_found(Plug.Conn.t()) :: Plug.Conn.t()
  def not_found(conn),
    do: conn |> put_resp_content_type("text/plain") |> send_resp(404, "Not Found")
end
