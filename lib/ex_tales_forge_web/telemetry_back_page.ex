defmodule TalesForgeWeb.TelemetryBackPage do
  @moduledoc """
  A "← Admin" entry in LiveDashboard's menu (`/admin/operate/telemetry`), the
  way back to the admin area from the bare dashboard: opening it redirects to
  the admin home's Operate section.
  """
  use Phoenix.LiveDashboard.PageBuilder

  @impl true
  @spec menu_link(map(), map()) :: {:ok, String.t()}
  def menu_link(_session, _capabilities), do: {:ok, "← Admin › Operate"}

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket),
    do: {:ok, Phoenix.LiveView.redirect(socket, to: "/admin#section-operate")}

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <p><a href="/admin#section-operate">← Back to the admin area</a></p>
    """
  end
end
