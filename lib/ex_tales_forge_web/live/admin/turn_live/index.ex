defmodule TalesForgeWeb.AdminLive.TurnLive.Index do
  @moduledoc """
  Admin: the turns of one game session.
  """

  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents

  alias TalesForge.Admin

  @impl true
  def mount(%{"id" => session_id}, _session, socket) do
    session = Admin.get_session!(session_id)
    turns = Admin.list_turns(session_id)

    {:ok,
     socket
     |> assign(:page_title, "Turns")
     |> assign(:session, session)
     |> assign(:turns, turns)
     |> assign(:selected_turn, nil)}
  end

  @impl true
  def handle_event("show_turn", %{"turn_id" => turn_id}, socket) do
    turn = Admin.get_turn!(socket.assigns.session.id, turn_id)
    {:noreply, assign(socket, :selected_turn, turn)}
  end

  def handle_event("hide_turn", _params, socket) do
    {:noreply, assign(socket, :selected_turn, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin socket={@socket} flash={@flash} active="sessions">
      <header class="space-y-2">
        <.link
          navigate={~p"/admin/play/sessions/#{@session.id}"}
          class="text-sm text-[var(--paper-accent)]"
        >
          ← {@session.name}
        </.link>
        <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">Turns</h2>
        <p class="text-sm text-[var(--paper-muted)]">Read-only audit trail.</p>
      </header>

      <div class="overflow-x-auto rounded-lg border border-[var(--paper-rule)]">
        <table class="min-w-full divide-y divide-[var(--paper-rule)] text-sm">
          <thead class="bg-[var(--paper-panel)] text-left text-[var(--paper-muted)]">
            <tr>
              <th class="px-4 py-2">#</th>
              <th class="px-4 py-2">Player action</th>
              <th class="px-4 py-2">Outcome</th>
              <th class="px-4 py-2">At</th>
              <th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody class="divide-y divide-[var(--paper-rule)]">
            <tr :for={turn <- @turns}>
              <td class="px-4 py-3">{turn.turn_number}</td>
              <td class="px-4 py-3 max-w-md truncate">{turn.player_action}</td>
              <td class="px-4 py-3">{Map.get(turn.mechanical_resolution, "outcome", "—")}</td>
              <td class="px-4 py-3">{format_time(turn.inserted_at)}</td>
              <td class="px-4 py-3">
                <button
                  type="button"
                  phx-click="show_turn"
                  phx-value-turn_id={turn.id}
                  class="text-[var(--paper-accent)]"
                >
                  View
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.section_card :if={@selected_turn} title={"Turn #{@selected_turn.turn_number}"}>
        <button type="button" phx-click="hide_turn" class="text-sm text-[var(--paper-muted)]">Close</button>
        <h3 class="play-label text-[var(--paper-muted)]">Player action</h3>
        <pre class="whitespace-pre-wrap rounded bg-[var(--paper-bg)] p-3 text-sm">{@selected_turn.player_action}</pre>
        <h3 class="play-label text-[var(--paper-muted)]">Narrative</h3>
        <pre class="whitespace-pre-wrap rounded bg-[var(--paper-bg)] p-3 text-sm">{@selected_turn.narrative}</pre>
        <h3 class="play-label text-[var(--paper-muted)]">Mechanical resolution</h3>
        <pre class="overflow-x-auto rounded bg-[var(--paper-bg)] p-3 text-xs">
          {Admin.encode_json(@selected_turn.mechanical_resolution)}
        </pre>
      </.section_card>
    </Layouts.admin>
    """
  end

  defp format_time(nil), do: "—"

  defp format_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end
end
