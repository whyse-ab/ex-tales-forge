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
        {:cont, socket |> assign(:admin_email, email) |> reload_on_stale_assets()}
    end
  end

  def on_mount(:maybe_admin, _params, session, socket) do
    {:cont,
     socket
     |> assign(:admin_email, AdminAuth.current_email(session))
     |> reload_on_stale_assets()}
  end

  # A tab opened before a deploy keeps the old <link>/<script> in <head>: the
  # LiveSocket silently reconnects to the new release and re-renders the body,
  # but the browser keeps the old digested CSS (so new styles never apply).
  # When the tracked static assets changed, force a full page load instead.
  defp reload_on_stale_assets(socket) do
    if connected?(socket) and static_changed?(socket) do
      attach_hook(socket, :reload_on_stale_assets, :handle_params, fn _params, uri, socket ->
        {:halt, redirect(socket, external: uri)}
      end)
    else
      socket
    end
  end
end
