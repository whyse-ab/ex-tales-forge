defmodule TalesForgeWeb.AdminSessionController do
  use TalesForgeWeb, :controller

  alias TalesForge.AdminAuth

  # Only point at /dev/mailbox when the router actually mounts it.
  @sent_message "If that email is allowlisted, a login link is on its way." <>
                  if(Application.compile_env(:ex_tales_forge, :dev_routes, false),
                    do: " In dev, check /dev/mailbox.",
                    else: ""
                  )

  def create(conn, %{"email" => email}) do
    :ok = AdminAuth.request_magic_link(email)

    conn
    |> put_flash(:info, @sent_message)
    |> redirect(to: ~p"/admin/login")
  end

  def magic(conn, %{"token" => token}) do
    case AdminAuth.verify_token(token) do
      {:ok, email} ->
        return_to = get_session(conn, "admin_return_to") || ~p"/admin"

        conn
        |> AdminAuth.put_session(email)
        |> delete_session("admin_return_to")
        |> put_flash(:info, "Signed in as #{email}")
        |> redirect(to: return_to)

      {:error, _} ->
        conn
        |> put_flash(:error, "That login link is invalid or expired.")
        |> redirect(to: ~p"/admin/login")
    end
  end

  def delete(conn, _params) do
    conn
    |> AdminAuth.clear_session()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/admin/login")
  end
end
