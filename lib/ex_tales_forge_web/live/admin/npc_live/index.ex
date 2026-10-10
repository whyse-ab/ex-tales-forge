defmodule TalesForgeWeb.AdminLive.NpcLive.Index do
  @moduledoc """
  Admin: the NPCs of one game session.
  """

  use TalesForgeWeb, :live_view

  alias TalesForge.Admin

  @impl true
  def mount(%{"id" => session_id}, _session, socket) do
    session = Admin.get_session!(session_id)
    npcs = Admin.list_npc_instances(session_id)

    {:ok,
     socket
     |> assign(:page_title, "NPC instances")
     |> assign(:session, session)
     |> assign(:npcs, npcs)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active="sessions">
      <header class="space-y-2">
        <.link
          navigate={~p"/admin/play/sessions/#{@session.id}"}
          class="text-sm text-[var(--paper-accent)]"
        >
          ← {@session.name}
        </.link>
        <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">NPC instances</h2>
      </header>

      <div class="overflow-x-auto rounded-lg border border-[var(--paper-rule)]">
        <table class="min-w-full divide-y divide-[var(--paper-rule)] text-sm">
          <thead class="bg-[var(--paper-panel)] text-left text-[var(--paper-muted)]">
            <tr>
              <th class="px-4 py-2">NPC</th>
              <th class="px-4 py-2">Location</th>
              <th class="px-4 py-2">Mood</th>
              <th class="px-4 py-2">Disposition</th>
              <th class="px-4 py-2">Stock items</th>
              <th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-[var(--paper-rule)]">
            <tr :for={npc <- @npcs}>
              <td class="px-4 py-3 font-medium">{npc.npc_id}</td>
              <td class="px-4 py-3">{Map.get(npc.runtime_state, "location_id", "—")}</td>
              <td class="px-4 py-3">{Map.get(npc.runtime_state, "mood", "—")}</td>
              <td class="px-4 py-3">{npc.disposition}</td>
              <td class="px-4 py-3">{stock_count(npc)}</td>
              <td class="px-4 py-3">
                <.link
                  navigate={~p"/admin/play/sessions/#{@session.id}/npcs/#{npc.npc_id}"}
                  class="text-[var(--paper-accent)]"
                >
                  Edit
                </.link>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.admin>
    """
  end

  defp stock_count(%{runtime_state: runtime}) do
    runtime
    |> Map.get("stock", [])
    |> length()
  end
end
