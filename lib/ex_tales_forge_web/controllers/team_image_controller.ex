defmodule TalesForgeWeb.TeamImageController do
  @moduledoc """
  Serves the images of the shared image store (`TalesForge.Images`).

  - `GET /team/images/:id` (`show/2`): for signed-in team members. The
    `:browser` pipeline checks the sign-in.
  - `GET /internal/images/:id` (`api/2`): for the bots, with the board bearer
    token (`TalesForge.BoardApi.bot_for_token/1`); missing or unknown: 401.

  Both live where the board lives (`TalesForge.AppRole.here?(:board)`);
  elsewhere 404. The answer has the stored content type, `nosniff`, and a
  private cache header, so no shared cache keeps a copy.
  """

  use TalesForgeWeb, :controller

  alias TalesForge.AppRole
  alias TalesForge.BoardApi
  alias TalesForge.Images
  alias TalesForgeWeb.PeerToken

  @doc "Sends one image to a signed-in team member, or 404."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}), do: send_image(conn, id)

  @doc "Sends one image to a bot with a board token: 401 without one, 404 for an unknown image."
  @spec api(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def api(conn, %{"id" => id}) do
    if AppRole.here?(:board) do
      case conn |> bearer() |> BoardApi.bot_for_token() do
        nil -> PeerToken.unauthorized(conn)
        _bot -> send_image(conn, id)
      end
    else
      PeerToken.not_found(conn)
    end
  end

  defp send_image(conn, id) do
    with true <- AppRole.here?(:board),
         %{} = image <- Images.get_with_data(id) do
      conn
      |> put_resp_content_type(image.content_type, nil)
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-disposition", "inline")
      |> send_resp(200, image.data)
    else
      _ -> conn |> put_resp_content_type("text/plain") |> send_resp(404, "Not found")
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end
end
