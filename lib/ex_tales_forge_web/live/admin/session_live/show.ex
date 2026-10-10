defmodule TalesForgeWeb.AdminLive.SessionLive.Show do
  @moduledoc """
  Admin: one game session, with an Ecto changeset form to edit it.
  """

  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents

  alias TalesForge.Admin

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    session = Admin.get_session!(id)

    {:ok,
     socket
     |> assign(:page_title, session.name)
     |> assign_session(session)}
  end

  @impl true
  def handle_event("save_session", %{"session" => params}, socket) do
    case Admin.update_session(socket.assigns.session, params) do
      {:ok, session} ->
        {:noreply,
         socket
         |> assign_session(session)
         |> put_flash(:info, "Session updated.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: "session"))}
    end
  end

  def handle_event("validate_session", %{"session" => params}, socket) do
    changeset =
      socket.assigns.session
      |> Admin.change_session(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: "session"))}
  end

  def handle_event("save_world_state", %{"world_state_json" => json}, socket) do
    case Admin.update_session_world_state(socket.assigns.session, json) do
      {:ok, session} ->
        {:noreply,
         socket
         |> assign_session(session)
         |> put_flash(:info, "World state saved.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("reseed_npcs", _params, socket) do
    case Admin.reset_session_npcs(socket.assigns.session) do
      {:ok, session} ->
        {:noreply,
         socket
         |> assign_session(session)
         |> put_flash(:info, "NPC instances reseeded from priv/npcs.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, inspect(reason))}
    end
  end

  def handle_event("delete", _params, socket) do
    Admin.delete_session(socket.assigns.session)
    {:noreply, push_navigate(socket, to: ~p"/admin/play/sessions")}
  end

  defp assign_session(socket, session) do
    socket
    |> assign(:session, session)
    |> assign(:world_state_json, Admin.encode_json(session.world_state || %{}))
    |> assign(:form, to_form(Admin.change_session(session), as: "session"))
  end

  @impl true
  def render(assigns) do
    character = get_in(assigns.session.world_state, ["character"]) || %{}

    assigns = assign(assigns, :character, character)

    ~H"""
    <Layouts.admin flash={@flash} active="sessions">
      <header class="space-y-2">
        <.link navigate={~p"/admin/play/sessions"} class="text-sm text-[var(--paper-accent)]">← Sessions</.link>
        <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">{@session.name}</h2>
        <p class="text-sm text-[var(--paper-muted)] font-mono">{@session.id}</p>
      </header>

      <div class="flex flex-wrap gap-2">
        <.link
          navigate={~p"/play/#{@session.id}"}
          class="rounded bg-[var(--paper-accent)] px-3 py-1.5 text-sm text-[var(--paper-on-accent)]"
        >
          Open in play
        </.link>
        <.link
          navigate={~p"/admin/play/sessions/#{@session.id}/npcs"}
          class="rounded border border-[var(--paper-rule)] px-3 py-1.5 text-sm"
        >
          NPC instances
        </.link>
        <.link
          navigate={~p"/admin/play/sessions/#{@session.id}/turns"}
          class="rounded border border-[var(--paper-rule)] px-3 py-1.5 text-sm"
        >
          Turns
        </.link>
      </div>

      <.section_card title="Summary">
        <dl class="grid gap-2 text-sm sm:grid-cols-2">
          <div>
            <dt class="text-[var(--paper-muted)]">Character</dt><dd>
              {Map.get(@character, "name", "—")}
            </dd>
          </div>
          <div>
            <dt class="text-[var(--paper-muted)]">Location</dt><dd>
              {Map.get(@session.world_state, "location_name", "—")}
            </dd>
          </div>
          <div>
            <dt class="text-[var(--paper-muted)]">World tick</dt><dd>
              {Map.get(@session.world_state, "world_tick", "—")}
            </dd>
          </div>
          <div>
            <dt class="text-[var(--paper-muted)]">Inventory items</dt>
            <dd>{length(Map.get(@character, "inventory", []))}</dd>
          </div>
        </dl>
      </.section_card>

      <.section_card title="Session fields">
        <.form
          for={@form}
          id="session-form"
          phx-submit="save_session"
          phx-change="validate_session"
          class="space-y-3"
        >
          <.input field={@form[:name]} type="text" label="Name" />
          <.input
            field={@form[:status]}
            type="select"
            label="Status"
            options={[
              {"Active", "active"},
              {"Paused", "paused"},
              {"Completed", "completed"},
              {"Dead", "dead"}
            ]}
          />
          <button
            type="submit"
            class="rounded bg-[var(--paper-accent)] px-4 py-2 text-sm text-[var(--paper-on-accent)]"
          >
            Save
          </button>
        </.form>
      </.section_card>

      <.section_card title="World state (JSON)">
        <form phx-submit="save_world_state" class="space-y-3">
          <.json_editor id="world_state_json" label="world_state" value={@world_state_json} rows={24} />
          <button
            type="submit"
            class="rounded bg-[var(--paper-accent)] px-4 py-2 text-sm text-[var(--paper-on-accent)]"
          >
            Save world state
          </button>
        </form>
      </.section_card>

      <.section_card title="Danger zone">
        <div class="flex flex-wrap gap-2">
          <button
            type="button"
            phx-click="reseed_npcs"
            data-confirm="Delete all NPC instances for this session and reseed from priv/npcs?"
            class="rounded border border-[var(--paper-rule)] px-3 py-1.5 text-sm"
          >
            Reseed NPCs
          </button>
          <button
            type="button"
            phx-click="delete"
            data-confirm="Delete this session permanently?"
            class="rounded border border-[var(--paper-danger-rule)] px-3 py-1.5 text-sm text-[var(--paper-danger-ink)]"
          >
            Delete session
          </button>
        </div>
      </.section_card>
    </Layouts.admin>
    """
  end
end
