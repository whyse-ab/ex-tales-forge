defmodule TalesForgeWeb.LiveAuth do
  @moduledoc """
  Default `on_mount` for every LiveView (`use TalesForgeWeb, :live_view`) and for
  LiveDashboard: halts the mount with a redirect to `/admin/login` unless the
  session belongs to a signed-in, still active GitHub team member.

  The router's live_sessions run `TalesForgeWeb.AdminLive.Hooks` first; this is
  the safety net for a LiveView mounted outside them, so a new LiveView is
  protected even if its route is added in the wrong place. It also marks the
  founder as online on this page (`TalesForge.Online.track/2`). Only the login page
  opts out (`use TalesForgeWeb, :public_live_view`).
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  alias TalesForge.AdminAuth
  alias TalesForge.Online

  @doc "Continues for a team member (assigning `:admin_email`), otherwise redirects to login."
  @spec on_mount(atom(), map() | :not_mounted_at_router, map(), Phoenix.LiveView.Socket.t()) ::
          {:cont | :halt, Phoenix.LiveView.Socket.t()}
  def on_mount(_name, _params, session, socket) do
    case AdminAuth.current_email(session) do
      nil ->
        {:halt, redirect(socket, to: "/admin/login")}

      email ->
        :ok = Online.track(socket, email)
        {:cont, assign(socket, :admin_email, email)}
    end
  end
end
