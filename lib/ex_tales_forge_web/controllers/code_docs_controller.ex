defmodule TalesForgeWeb.CodeDocsController do
  @moduledoc """
  `GET /admin/code-docs/*path`: the ExDoc HTML site for this codebase, team members only.

  The route sits in the `:browser` pipeline (`TalesForgeWeb.Plugs.RequireTeamMember`),
  so every page and asset under `/admin/code-docs` needs a signed-in GitHub team
  member; anyone else is redirected to `/admin/login`, just like `/admin/costs`.
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

      File.regular?(file) and Path.extname(file) == ".html" ->
        conn
        |> allow_js()
        |> put_resp_content_type("text/html")
        |> put_resp_header("cache-control", "private, max-age=300")
        |> send_resp(200, with_back_link(File.read!(file)))

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

  @back_link ~s|<nav id="admin-back" aria-label="Breadcrumb" style="position:fixed;right:.75rem;bottom:.75rem;z-index:1000;padding:.4rem .75rem;border-radius:999px;background:#3b2a1a;color:#fff;font:600 13px/1.3 system-ui,sans-serif;box-shadow:0 2px 6px rgba(0,0,0,.25)"><a href="/admin" style="color:#fff">Admin</a> › <a href="/admin#section-develop" style="color:#fff">Develop</a> › <span aria-current="page">Code docs</span></nav>|

  @doc """
  ExDoc's HTML with a small fixed "Admin › Develop › Code docs" breadcrumb
  added right after `<body ...>`, the way back to the admin area (ExDoc has no
  admin layout). HTML without a body tag is returned unchanged.
  """
  @spec with_back_link(String.t()) :: String.t()
  def with_back_link(html) do
    case Regex.run(~r/<body[^>]*>/i, html, return: :index) do
      [{start, len}] ->
        {head, rest} = String.split_at(html, start + len)
        head <> @back_link <> rest

      nil ->
        html
    end
  end

  # Plug.CSRFProtection (in the :admin pipeline) refuses to send JavaScript to a
  # plain GET, to stop other sites embedding it with <script src>. ExDoc's
  # sidebar and search are static JS loaded by <script> tags, so they got 403.
  # Skipping that check here is safe: these files are static, hold no tokens,
  # and the session cookie is SameSite=Lax, so a cross-site <script> request
  # carries no session and RequireTeamMember redirects it to the login page.
  defp allow_js(conn), do: put_private(conn, :plug_skip_csrf_protection, true)

  defp not_found(conn, message),
    do: conn |> put_resp_content_type("text/plain") |> send_resp(404, message)
end
