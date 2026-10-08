defmodule TalesForgeWeb.DocFilesController do
  @moduledoc """
  `GET /admin/docs-files/*path`: an image of a tales-forge-docs page, for the
  docs viewer (`TalesForge.Collab.Links` points `![...](images/x.png)` here).

  The docs repo is private, so the browser can't load its images from GitHub;
  the server reads them (`TalesForge.Collab.Files`). Team members only, like
  every page (`:browser` pipeline). Anything that is not an image under `docs/`
  answers 404.
  """

  use TalesForgeWeb, :controller

  alias TalesForge.Collab.Files

  @doc "Sends the image, cached by the browser for an hour; 404 otherwise."
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"path" => segments}) do
    case Files.fetch(Enum.join(segments, "/")) do
      {:ok, bytes, type} ->
        conn
        |> put_resp_content_type(type, nil)
        |> put_resp_header("cache-control", "private, max-age=3600")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_resp(200, bytes)

      {:error, :not_found} ->
        conn |> put_resp_content_type("text/plain") |> send_resp(404, "Not Found")
    end
  end
end
