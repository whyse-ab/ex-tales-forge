defmodule TalesForgeWeb.AdminLive.SessionLive.Index do
  @moduledoc """
  Admin: list of game sessions.
  """

  use TalesForgeWeb, :live_view

  alias TalesForge.Admin

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Sessions")
     |> assign(:sessions, Admin.list_sessions())}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    session = Admin.get_session!(id)
    :ok = Admin.delete_session(session)

    {:noreply,
     socket
     |> put_flash(:info, "Session deleted.")
     |> assign(:sessions, Admin.list_sessions())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active="sessions">
      <header class="flex items-center justify-between gap-4">
        <div>
          <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">Sessions</h2>
          <p class="text-sm text-[var(--paper-muted)]">Game sessions stored in PostgreSQL.</p>
        </div>
      </header>

      <div class="overflow-x-auto rounded-lg border border-[var(--paper-rule)]">
        <table class="min-w-full divide-y divide-[var(--paper-rule)] text-sm">
          <thead class="bg-[var(--paper-panel)] text-left text-[var(--paper-muted)]">
            <tr>
              <th class="px-4 py-2">Name</th>
              <th class="px-4 py-2">Status</th>
              <th class="px-4 py-2">Character</th>
              <th class="px-4 py-2">Location</th>
              <th class="px-4 py-2">Turns</th>
              <th class="px-4 py-2">Actions</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-[var(--paper-rule)] bg-[var(--paper-bg)]">
            <tr :for={row <- @sessions}>
              <td class="px-4 py-3 font-medium text-[var(--paper-ink)]">{row.session.name}</td>
              <td class="px-4 py-3">{row.session.status}</td>
              <td class="px-4 py-3">{row.character_name}</td>
              <td class="px-4 py-3">{row.location_name}</td>
              <td class="px-4 py-3">{row.turn_count}</td>
              <td class="px-4 py-3 space-x-2">
                <.link
                  navigate={~p"/admin/sessions/#{row.session.id}"}
                  class="text-[var(--paper-accent)]"
                >
                  View
                </.link>
                <.link navigate={~p"/play/#{row.session.id}"} class="text-[var(--paper-accent)]">Play</.link>
                <button
                  type="button"
                  phx-click="delete"
                  phx-value-id={row.session.id}
                  data-confirm="Delete this session and all turns/NPC instances?"
                  class="text-[var(--paper-danger-ink)]"
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.admin>
    """
  end
end
