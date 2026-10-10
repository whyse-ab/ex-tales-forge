defmodule TalesForgeWeb.AdminLive.NpcDefinitionLive.Show do
  @moduledoc """
  Admin: one NPC definition from the adventure pack, as read-only JSON.
  The pack files in `priv/npcs` are edited in git, not here.
  """

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
  rescue
    ArgumentError ->
      {:ok,
       socket
       |> put_flash(:error, "No NPC definition #{inspect(npc_id)}.")
       |> push_navigate(to: ~p"/admin/archive/npc-definitions")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin socket={@socket} flash={@flash} active="npc_definitions">
      <header class="space-y-2">
        <.link
          navigate={~p"/admin/archive/npc-definitions"}
          class="text-sm text-[var(--paper-accent)]"
        >
          ← NPC definitions
        </.link>
        <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">{@npc_id}</h2>
      </header>

      <.section_card title="Definition JSON (read-only)">
        <p class="text-xs text-[var(--paper-muted)]">
          priv/npcs/{@npc_id}.json. Pack files are edited in git and ship with a deploy.
        </p>
        <pre
          id="definition_json"
          class="overflow-x-auto rounded bg-[var(--paper-bg)] p-3 text-xs"
        >{@json}</pre>
      </.section_card>
    </Layouts.admin>
    """
  end
end
