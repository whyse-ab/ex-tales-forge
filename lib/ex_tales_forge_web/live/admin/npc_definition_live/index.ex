defmodule TalesForgeWeb.AdminLive.NpcDefinitionLive.Index do
  @moduledoc """
  Admin: list of NPC definitions from the adventure packs.
  """

  use TalesForgeWeb, :live_view

  alias TalesForge.Admin

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "NPC definitions")
     |> assign(:definitions, Admin.list_npc_definitions())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active="npc_definitions">
      <header class="space-y-1">
        <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">NPC definitions</h2>
        <p class="text-sm text-[var(--paper-muted)]">
          Read-only view of the pack files in priv/npcs; edit them in git. Changes apply to new sessions unless you reseed NPC instances.
        </p>
      </header>

      <div class="overflow-x-auto rounded-lg border border-[var(--paper-rule)]">
        <table class="min-w-full divide-y divide-[var(--paper-rule)] text-sm">
          <thead class="bg-[var(--paper-panel)] text-left text-[var(--paper-muted)]">
            <tr>
              <th class="px-4 py-2">ID</th>
              <th class="px-4 py-2">Name</th>
              <th class="px-4 py-2">Role</th>
              <th class="px-4 py-2">Default location</th>
              <th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-[var(--paper-rule)]">
            <tr :for={npc <- @definitions}>
              <td class="px-4 py-3 font-mono">{npc.id}</td>
              <td class="px-4 py-3">{npc.name}</td>
              <td class="px-4 py-3">{npc.role}</td>
              <td class="px-4 py-3">{npc.default_location_id}</td>
              <td class="px-4 py-3">
                <.link
                  navigate={~p"/admin/npc-definitions/#{npc.id}"}
                  class="text-[var(--paper-accent)]"
                >
                  Edit JSON
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.admin>
    """
  end
end
