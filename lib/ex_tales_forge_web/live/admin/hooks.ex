defmodule TalesForgeWeb.AdminLive.Hooks do
  @moduledoc """
  `on_mount` hooks for the router's live_sessions. `:require_team_member` (play
  and admin pages) halts with a redirect to `/admin/login` unless the session
  belongs to an active ADMIN_GITHUB_TEAM member; `:maybe_team_member` (the login
  page) only assigns `:admin_email` when there is one. Both reload a tab whose
  static assets are stale.
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias TalesForge.AdminAuth

  @doc "See the moduledoc."
  @spec on_mount(atom(), map() | :not_mounted_at_router, map(), Phoenix.LiveView.Socket.t()) ::
          {:cont | :halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:require_team_member, _params, session, socket) do
    case AdminAuth.current_email(session) do
      nil ->
        {:halt, redirect(socket, to: "/admin/login")}

      email ->
        {:cont, socket |> assign(:admin_email, email) |> reload_on_stale_assets()}
    end
  end

  def on_mount(:maybe_team_member, _params, session, socket) do
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
