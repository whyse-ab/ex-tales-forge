defmodule TalesForgeWeb.AdminLive.NpcDefinitionLive.Show do
  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents

  alias TalesForge.Admin

  @impl true
  def mount(%{"id" => npc_id}, _session, socket) do
    json = Admin.npc_definition_json(npc_id)

    {:ok,
     socket
     |> assign(:page_title, npc_id)
     |> assign(:npc_id, npc_id)
     |> assign(:json, json)}
  end

  @impl true
  def handle_event("save", %{"definition_json" => json}, socket) do
    case Admin.save_npc_definition(socket.assigns.npc_id, json) do
      {:ok, _definition} ->
        {:noreply,
         socket
         |> assign(:json, Admin.npc_definition_json(socket.assigns.npc_id))
         |> put_flash(:info, "NPC definition saved.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active="npc_definitions">
      <header class="space-y-2">
        <.link navigate={~p"/admin/npc-definitions"} class="text-sm text-[var(--paper-accent)]">
          ← NPC definitions
        </.link>
        <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">{@npc_id}</h2>
      </header>

      <.section_card title="Definition JSON">
        <form phx-submit="save" class="space-y-3">
          <.json_editor
            id="definition_json"
            label="priv/npcs/#{@npc_id}.json"
            value={@json}
            rows={28}
          />
          <button
            type="submit"
            class="rounded bg-[var(--paper-accent)] px-4 py-2 text-sm text-[var(--paper-on-accent)]"
          >
            Save to disk
          </button>
        </form>
      </.section_card>
    </Layouts.admin>
    """
  end
end
