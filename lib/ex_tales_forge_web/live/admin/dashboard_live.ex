defmodule TalesForgeWeb.AdminLive.DashboardLive do
  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents

  alias TalesForge.Admin

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> assign(:stats, Admin.stats())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active="dashboard">
      <header class="space-y-1">
        <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">Dashboard</h2>
        <p class="text-[var(--paper-muted)]">
          Database and content operations without leaving the app.
        </p>
      </header>

      <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        <.stat_card label="Sessions" value={@stats.sessions} />
        <.stat_card label="Active sessions" value={@stats.active_sessions} />
        <.stat_card label="Turns" value={@stats.turns} />
        <.stat_card label="NPC instances" value={@stats.npc_instances} />
        <.stat_card label="Scenes" value={@stats.scenes} />
      </div>

      <.section_card title="Quick links">
        <ul class="space-y-2 text-sm">
          <li>
            <.link navigate={~p"/admin/decisions"} class="text-[var(--paper-accent)]">Decision queue</.link>
          </li>
          <li>
            <.link navigate={~p"/admin/docs"} class="text-[var(--paper-accent)]">Shared docs</.link>
          </li>
          <li>
            <.link navigate={~p"/admin/sessions"} class="text-[var(--paper-accent)]">Manage sessions</.link>
          </li>
          <li>
            <.link navigate={~p"/admin/npc-definitions"} class="text-[var(--paper-accent)]">
              Edit NPC definitions
            </.link>
          </li>
          <li>
            <.link navigate={~p"/admin/oban"} class="text-[var(--paper-accent)]">Oban / telemetry</.link>
          </li>
        </ul>
      </.section_card>
    </Layouts.admin>
    """
  end
end
