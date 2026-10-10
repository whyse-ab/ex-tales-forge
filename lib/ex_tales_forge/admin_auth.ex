defmodule TalesForge.AdminAuth do
  @moduledoc """
  Sign-in for the whole app: "Sign in with GitHub" (`TalesForge.AdminAuth.GitHub`)
  for active members of the ADMIN_GITHUB_TEAM GitHub team (`whyse-ab/tales-forge`).
  It is the only way in, and it gates every page and LiveView (players and the
  /admin area alike; any team member gets the admin pages, there is no second
  admin check). Email magic links were removed on 2026-10-07.

  The session holds `admin_email` and `admin_github_login`, never a token. Every
  request and LiveView mount rechecks it via `current_email/1`: the GitHub login
  must still be an active team member (cached for a few minutes). A session
  without a GitHub login (e.g. an old magic-link cookie) is no longer valid.
  """

  alias TalesForge.AdminAuth.GitHub

  @session_key "admin_email"
  @github_login_key "admin_github_login"

  @doc "Session key holding the signed-in user's email."
  @spec session_key() :: String.t()
  def session_key, do: @session_key

  @doc """
  `path` when it is a safe place to return to after sign-in: a path on this
  app (starts with one `/`, no scheme, host, backslash or control
  characters), with its query. Anything else is nil.

      iex> TalesForge.AdminAuth.safe_return_to("/admin/play/runs?x=1")
      "/admin/play/runs?x=1"
      iex> TalesForge.AdminAuth.safe_return_to("//evil.example/x")
      nil
      iex> TalesForge.AdminAuth.safe_return_to("https://evil.example/")
      nil
      iex> TalesForge.AdminAuth.safe_return_to("/admin/login")
      nil
  """
  @spec safe_return_to(term()) :: String.t() | nil
  def safe_return_to("/" <> rest = path) do
    cond do
      String.starts_with?(rest, ["/", "\\"]) -> nil
      String.contains?(path, ["\\", "\r", "\n", "\t"]) -> nil
      String.length(path) > 2000 -> nil
      String.starts_with?(path, ["/admin/login", "/admin/auth/"]) -> nil
      URI.parse(path).host != nil -> nil
      true -> path
    end
  end

  def safe_return_to(_path), do: nil

  @doc "Session key holding the signed-in user's GitHub login."
  @spec github_login_key() :: String.t()
  def github_login_key, do: @github_login_key

  @doc "Starts a session for a GitHub team member (after the OAuth callback)."
  @spec put_github_session(Plug.Conn.t(), %{login: String.t(), email: String.t()}) ::
          Plug.Conn.t()
  def put_github_session(conn, %{login: login, email: email}) do
    conn
    |> Plug.Conn.configure_session(renew: true)
    |> Plug.Conn.put_session(@session_key, normalize(email))
    |> Plug.Conn.put_session(@github_login_key, login)
  end

  @doc "Signs out: drops the identity keys from the session."
  @spec clear_session(Plug.Conn.t()) :: Plug.Conn.t()
  def clear_session(conn) do
    conn
    |> Plug.Conn.delete_session(@session_key)
    |> Plug.Conn.delete_session(@github_login_key)
  end

  @doc """
  The signed-in user's email, or nil. Rechecked every time: the session must
  carry a GitHub login that is still an active member of ADMIN_GITHUB_TEAM.

      iex> TalesForge.AdminAuth.current_email(%{})
      nil
      iex> TalesForge.AdminAuth.current_email(%{"admin_email" => "old@magic.link"})
      nil
  """
  @spec current_email(Plug.Conn.t() | map() | term()) :: String.t() | nil
  def current_email(%Plug.Conn{} = conn), do: current_email(Plug.Conn.get_session(conn))

  def current_email(%{@session_key => email, @github_login_key => login})
      when is_binary(email) and is_binary(login) do
    if GitHub.team_member?(login), do: normalize(email)
  end

  def current_email(_), do: nil

  @doc """
  Trims and downcases an email.

      iex> TalesForge.AdminAuth.normalize("  Octo@Example.COM ")
      "octo@example.com"
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(email) when is_binary(email), do: email |> String.trim() |> String.downcase()
end
