defmodule TalesForge.AdminAuth do
  @moduledoc """
  Email magic-link auth for the /admin section, restricted to ADMIN_EMAILS.
  """

  import Ecto.Query

  alias TalesForge.Collab.Schemas.MagicToken
  alias TalesForge.Mailer
  alias TalesForge.Repo
  alias TalesForgeWeb.Endpoint

  @token_ttl_minutes 30
  @session_key "admin_email"

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
      nil ->
        {:error, :invalid}

      %MagicToken{expires_at: expires_at} = mt ->
        if DateTime.compare(expires_at, now) == :lt do
          Repo.delete(mt)
          {:error, :expired}
        else
          email = mt.email
          Repo.delete(mt)

          if allowlisted?(email) do
            {:ok, email}
          else
            {:error, :not_allowlisted}
          end
        end
    end
  end

  def put_session(conn, email) do
    Plug.Conn.put_session(conn, @session_key, normalize(email))
  end

  def clear_session(conn) do
    Plug.Conn.delete_session(conn, @session_key)
  end

  def current_email(%Plug.Conn{} = conn) do
    case Plug.Conn.get_session(conn, @session_key) do
      email when is_binary(email) -> normalize_if_allowed(email)
      _ -> nil
    end
  end

  def current_email(session) when is_map(session) do
    case Map.get(session, @session_key) do
      email when is_binary(email) -> normalize_if_allowed(email)
      _ -> nil
    end
  end

  defp normalize_if_allowed(email) do
    email = normalize(email)
    if allowlisted?(email), do: email, else: nil
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

  defp normalize(email) when is_binary(email), do: email |> String.trim() |> String.downcase()
end
