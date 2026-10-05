defmodule TalesForgeWeb.AdminLive.Hooks do
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView

  alias TalesForge.AdminAuth

  def on_mount(:require_admin, _params, session, socket) do
    case AdminAuth.current_email(session) do
      nil ->
        {:halt, redirect(socket, to: "/admin/login")}

      email ->
        {:cont, assign(socket, :admin_email, email)}
    end
  end

  def on_mount(:maybe_admin, _params, session, socket) do
    {:cont, assign(socket, :admin_email, AdminAuth.current_email(session))}
  end
end
