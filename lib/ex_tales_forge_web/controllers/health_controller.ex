defmodule TalesForgeWeb.HealthController do
  @moduledoc """
  `GET /health`: the Fly HTTP health check (fly.toml, fly.playtest.toml). Public
  on purpose, since everything else needs a signed-in team member: answers
  `200 ok` without touching the session, the database or any AI service.
  """

  use TalesForgeWeb, :controller

  @doc "Plain `200 ok`."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end
end
