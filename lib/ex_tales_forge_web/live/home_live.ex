defmodule TalesForgeWeb.HomeLive do
  use TalesForgeWeb, :live_view

  alias TalesForge.GameSessions

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Tales Forge")
     |> assign(:sessions, GameSessions.list_sessions())}
  end

  @impl true
  def handle_event("new_session", %{"adventure" => adventure}, socket) do
    start_session(socket, adventure)
  end

  def handle_event("new_session", _params, socket) do
    start_session(socket, "crossroads_ledger")
  end

  defp start_session(socket, adventure) do
    {name, adventure_id} =
      case adventure do
        "tin_valley" -> {"Tin Valley", "tin_valley"}
        _ -> {"Crossroads Hamlet", "crossroads_ledger"}
      end

    case GameSessions.create_session(%{name: name, adventure_id: adventure_id}) do
      {:ok, session} ->
        {:noreply, push_navigate(socket, to: ~p"/play/#{session.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not start a new session.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <header class="space-y-2">
        <p class="play-label text-[var(--paper-accent)]">Tales Forge</p>
        <h1 class="font-serif text-3xl font-bold text-[var(--paper-ink)]">Your adventures await</h1>
        <p class="text-[var(--paper-muted)]">
          Text-first AI RPG on the BEAM. You act at the table; factions act too.
        </p>
      </header>

      <div class="flex flex-wrap gap-3">
        <button
          phx-click="new_session"
          phx-value-adventure="tin_valley"
          class="rounded bg-[var(--paper-accent)] px-4 py-2 font-medium text-white hover:opacity-90"
        >
          Start Tin Valley
        </button>
        <button
          phx-click="new_session"
          phx-value-adventure="crossroads_ledger"
          class="rounded border border-[var(--paper-rule)] px-4 py-2 font-medium text-[var(--paper-ink)] hover:opacity-80"
        >
          Crossroads Hamlet
        </button>
      </div>

      <section :if={@sessions != []} class="space-y-3">
        <h2 class="play-label">Recent sessions</h2>
        <ul class="divide-y divide-[var(--paper-rule)] rounded-lg border border-[var(--paper-rule)] bg-[var(--paper-panel)]">
          <li :for={session <- @sessions} class="px-4 py-3">
            <div class="flex items-center justify-between gap-3">
              <.link navigate={~p"/play/#{session.id}"} class="flex-1 hover:opacity-80">
                <span class="font-medium text-[var(--paper-ink)]">{session.name}</span>
              </.link>
              <div class="flex items-center gap-3 text-sm">
                <.link
                  href={~p"/admin/sessions/#{session.id}"}
                  class="text-[var(--paper-muted)] hover:text-[var(--paper-accent)] hover:underline"
                >
                  Admin
                </.link>
                <span class="text-[var(--paper-muted)]">{session.status}</span>
              </div>
            </div>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end
end
