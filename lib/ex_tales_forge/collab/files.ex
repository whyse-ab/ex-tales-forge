defmodule TalesForge.Collab.Files do
  @moduledoc """
  Reads an image of the tales-forge-docs repo for the docs viewer
  (`TalesForgeWeb.DocFilesController`): from the local checkout in
  `TALES_FORGE_DOCS_PATH` when set, otherwise from GitHub with
  `GITHUB_DOCS_TOKEN` (the same sources as the docs sync). Only images under
  `docs/` are served, and only raster formats (an SVG could carry script).
  """

  @github_owner "whyse-ab"
  @github_repo "tales-forge-docs"
  @types %{
    ".png" => "image/png",
    ".jpg" => "image/jpeg",
    ".jpeg" => "image/jpeg",
    ".gif" => "image/gif",
    ".webp" => "image/webp"
  }

  @doc """
  `{:ok, bytes, content_type}` for the repo path `path` (e.g.
  `docs/images/score.png`), or `{:error, :not_found}` when it is not an image
  under `docs/`, doesn't exist, or no source is configured.
  """
  @spec fetch(String.t()) :: {:ok, binary(), String.t()} | {:error, :not_found}
  def fetch(path) when is_binary(path) do
    with {:ok, relative} <- safe_path(path),
         {:ok, type} <- Map.fetch(@types, relative |> Path.extname() |> String.downcase()),
         {:ok, bytes} <- read(relative) do
      {:ok, bytes, type}
    else
      _ -> {:error, :not_found}
    end
  end

  defp safe_path(path) do
    case Path.safe_relative(path) do
      {:ok, "docs/" <> _ = relative} -> {:ok, relative}
      _ -> :error
    end
  end

  defp read(relative) do
    cond do
      root = docs_path() -> File.read(Path.join(root, relative))
      token = System.get_env("GITHUB_DOCS_TOKEN") -> fetch_github(token, relative)
      true -> :error
    end
  end

  defp docs_path do
    case Application.get_env(:ex_tales_forge, :tales_forge_docs_path) do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  defp fetch_github(token, relative) do
    url = "https://api.github.com/repos/#{@github_owner}/#{@github_repo}/contents/#{relative}"

    case Req.get(
           url,
           [
             headers: [
               {"authorization", "Bearer #{token}"},
               {"accept", "application/vnd.github.raw"},
               {"user-agent", "tales-forge-docs-viewer"}
             ],
             params: [ref: "main"],
             decode_body: false,
             retry: false,
             receive_timeout: 10_000
           ] ++ Application.get_env(:ex_tales_forge, :docs_req_options, [])
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      _ -> :error
    end
  end
end
