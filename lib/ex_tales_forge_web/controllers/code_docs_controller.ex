defmodule TalesForgeWeb.CodeDocsController do
  @moduledoc """
  `GET /admin/code-docs/*path`: the ExDoc HTML site for this codebase, admin only.

  The route sits in the `:admin` pipeline (`TalesForgeWeb.Plugs.AdminAuth`), so
  every page and asset under `/admin/code-docs` needs an allowlisted admin
  session; anyone else is redirected to `/admin/login`, just like `/admin/costs`.
  The docs are not in `TalesForgeWeb.static_paths/0`, so the public
  `Plug.Static` never serves them.

  The release builds the docs in the Docker builder stage
  (`mix docs -f html -o priv/code_docs`) and ships only that HTML inside the
  release. Locally, run the same command to browse them here. When the folder
  is missing the page answers 404 with that hint.
  """

  use TalesForgeWeb, :controller

  @doc """
  Serves one file from the docs folder. `/admin/code-docs` redirects to
  `/admin/code-docs/` so ExDoc's relative links resolve; an empty path serves
  `index.html`. Paths that try to leave the folder, and missing files, get 404.
  """
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"path" => []}) do
    if String.ends_with?(conn.request_path, "/") do
      serve(conn, "index.html")
    else
      redirect(conn, to: conn.request_path <> "/")
    end
  end

  def show(conn, %{"path" => segments}) do
    case Path.safe_relative(Path.join(segments)) do
      {:ok, relative} -> serve(conn, relative)
      :error -> not_found(conn, "Not Found")
    end
  end

  @doc """
  The folder the docs are served from: the `:code_docs_dir` app setting when
  set (tests), otherwise `priv/code_docs` of the running app.
  """
  @spec docs_dir() :: Path.t()
  def docs_dir do
    Application.get_env(:ex_tales_forge, :code_docs_dir) ||
      Application.app_dir(:ex_tales_forge, "priv/code_docs")
  end

  defp serve(conn, relative) do
    dir = docs_dir()
    file = Path.join(dir, relative)

    cond do
      not File.dir?(dir) ->
        not_found(
          conn,
          "Code docs are not built here. Run `mix docs -f html -o priv/code_docs`."
        )

      File.regular?(file) ->
        conn
        |> allow_js()
        |> put_resp_content_type(MIME.from_path(file), nil)
        |> put_resp_header("cache-control", "private, max-age=300")
        |> send_file(200, file)

      true ->
        not_found(conn, "Not Found")
    end
  end

  # Plug.CSRFProtection (in the :admin pipeline) refuses to send JavaScript to a
  # plain GET, to stop other sites embedding it with <script src>. ExDoc's
  # sidebar and search are static JS loaded by <script> tags, so they got 403.
  # Skipping that check here is safe: these files are static, hold no tokens,
  # and the session cookie is SameSite=Lax, so a cross-site <script> request
  # carries no admin session and AdminAuth redirects it to the login page.
  defp allow_js(conn), do: put_private(conn, :plug_skip_csrf_protection, true)

  defp not_found(conn, message),
    do: conn |> put_resp_content_type("text/plain") |> send_resp(404, message)
end
