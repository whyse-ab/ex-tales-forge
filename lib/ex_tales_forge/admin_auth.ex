defmodule TalesForge.AdminAuth do
  @moduledoc """
  Auth for the /admin section: email magic links restricted to ADMIN_EMAILS,
  plus "Sign in with GitHub" (`TalesForge.AdminAuth.GitHub`).

  The session holds `admin_email` (and `admin_github_login` after a GitHub
  sign-in), never a token. Every request and LiveView mount rechecks it via
  `current_email/1`: the email must still be allowlisted or, for GitHub
  sessions, the login must still be an active member of ADMIN_GITHUB_TEAM.
  """

  import Ecto.Query

  alias TalesForge.AdminAuth.GitHub
  alias TalesForge.Collab.Schemas.MagicToken
  alias TalesForge.Mailer
  alias TalesForge.Repo
  alias TalesForgeWeb.Endpoint

  @token_ttl_minutes 30
  @session_key "admin_email"
  @github_login_key "admin_github_login"

  def session_key, do: @session_key

  def allowlisted?(email) when is_binary(email) do
    email = normalize(email)
    email in allowlist()
  end

  def allowlisted?(_), do: false

  def allowlist do
    Application.get_env(:ex_tales_forge, :admin_emails, [])
    |> List.wrap()
    |> Enum.map(&normalize/1)
    |> Enum.reject(&(&1 == ""))
  end

  def request_magic_link(email, opts \\ []) when is_binary(email) do
    email = normalize(email)

    cond do
      email == "" ->
        {:error, :invalid_email}

      not allowlisted?(email) ->
        # Do not reveal whether the email is allowlisted.
        :ok

      true ->
        token = generate_token()
        expires_at = DateTime.utc_now() |> DateTime.add(@token_ttl_minutes * 60, :second)

        Repo.delete_all(from(t in MagicToken, where: t.email == ^email))

        {:ok, _} =
          %MagicToken{}
          |> MagicToken.changeset(%{email: email, token: token, expires_at: expires_at})
          |> Repo.insert()

        url =
          Keyword.get_lazy(opts, :url, fn ->
            Endpoint.url() <> "/admin/magic/#{token}"
          end)

        email
        |> magic_link_email(url)
        |> Mailer.deliver()

        :ok
    end
  end

  def verify_token(token) when is_binary(token) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get_by(MagicToken, token: token) do
      nil -> {:error, :invalid}
      %MagicToken{} = mt -> consume_token(mt, now)
    end
  end

  # Tokens are single-use: delete it whether or not it is still valid.
  defp consume_token(%MagicToken{expires_at: expires_at, email: email} = mt, now) do
    Repo.delete(mt)

    cond do
      DateTime.compare(expires_at, now) == :lt -> {:error, :expired}
      allowlisted?(email) -> {:ok, email}
      true -> {:error, :not_allowlisted}
    end
  end

  @doc "Session for a magic-link login (drops any earlier GitHub identity)."
  def put_session(conn, email) do
    conn
    |> Plug.Conn.put_session(@session_key, normalize(email))
    |> Plug.Conn.delete_session(@github_login_key)
  end

  @doc "Session for a GitHub login."
  def put_github_session(conn, %{login: login, email: email}) do
    conn
    |> Plug.Conn.put_session(@session_key, normalize(email))
    |> Plug.Conn.put_session(@github_login_key, login)
  end

  def clear_session(conn) do
    conn
    |> Plug.Conn.delete_session(@session_key)
    |> Plug.Conn.delete_session(@github_login_key)
  end

  @doc """
  The signed-in admin email, or nil. Rechecked every time: allowlisted email,
  or (GitHub sessions only) active membership of ADMIN_GITHUB_TEAM.
  """
  def current_email(%Plug.Conn{} = conn), do: current_email(Plug.Conn.get_session(conn))

  def current_email(session) when is_map(session) do
    case Map.get(session, @session_key) do
      email when is_binary(email) ->
        recheck(normalize(email), Map.get(session, @github_login_key))

      _ ->
        nil
    end
  end

  def current_email(_), do: nil

  defp recheck(email, github_login) do
    cond do
      allowlisted?(email) -> email
      GitHub.team_member?(github_login) -> email
      true -> nil
    end
  end

  defp magic_link_email(email, url) do
    Swoosh.Email.new()
    |> Swoosh.Email.to(email)
    |> Swoosh.Email.from({"Tales Forge Admin", from_address()})
    |> Swoosh.Email.subject("Your Tales Forge admin login link")
    |> Swoosh.Email.text_body("""
    Click to sign in to the Tales Forge admin:

    #{url}

    This link expires in #{@token_ttl_minutes} minutes.
    If you did not request it, ignore this email.
    """)
  end

  defp from_address do
    System.get_env("ADMIN_MAIL_FROM") || "admin@tales-forge.ai"
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  def normalize(email) when is_binary(email), do: email |> String.trim() |> String.downcase()
end
