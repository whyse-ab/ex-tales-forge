defmodule TalesForgeWeb.AdminLive.DecisionLive.Index do
  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents

  alias TalesForge.Collab

  on_mount {TalesForgeWeb.AdminLive.Hooks, :require_admin}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Collab.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Decision queue")
     |> assign(:decisions, Collab.list_decisions())
     |> assign(:syncing, false)}
  end

  @impl true
  def handle_info({:decisions_updated}, socket) do
    {:noreply, assign(socket, :decisions, Collab.list_decisions())}
  end

  def handle_info({:decision_updated, _slug}, socket) do
    {:noreply, assign(socket, :decisions, Collab.list_decisions())}
  end

  @impl true
  def handle_event("move_up", %{"slug" => slug}, socket) do
    _ = Collab.move_decision(slug, :up)
    {:noreply, assign(socket, :decisions, Collab.list_decisions())}
  end

  def handle_event("move_down", %{"slug" => slug}, socket) do
    _ = Collab.move_decision(slug, :down)
    {:noreply, assign(socket, :decisions, Collab.list_decisions())}
  end

  def handle_event("sync", _params, socket) do
    result = do_sync()

    socket =
      case result do
        {:ok, stats} ->
          put_flash(
            socket,
            :info,
            "Synced #{stats.decisions.upserted} decisions, #{stats.docs.upserted} docs."
          )

        {:error, reason} ->
          put_flash(socket, :error, "Sync failed: #{inspect(reason)}")
      end

    {:noreply, assign(socket, :decisions, Collab.list_decisions())}
  end

  defp do_sync do
    cond do
      path = System.get_env("TALES_FORGE_DOCS_PATH") ->
        Collab.sync_from_path(path)

      token = System.get_env("GITHUB_DOCS_TOKEN") ->
        Collab.sync_from_github(token)

      File.dir?("/workspace/tales-forge-docs-git") ->
        Collab.sync_from_path("/workspace/tales-forge-docs-git")

      true ->
        {:error, :no_docs_source}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active="decisions">
      <header class="flex flex-wrap items-start justify-between gap-3">
        <div class="space-y-1">
          <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">Decision queue</h2>
          <p class="text-[var(--paper-muted)]">
            Ranked most important first. People self-select as interested — nobody assigns owners.
          </p>
        </div>
        <button
          type="button"
          phx-click="sync"
          class="rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-3 py-2 text-sm text-[var(--paper-ink)] hover:border-[var(--paper-accent)]"
        >
          Sync from repo
        </button>
      </header>

      <.section_card title="Queue">
        <%= if @decisions == [] do %>
          <p class="text-sm text-[var(--paper-muted)]">
            No decisions yet. Click <strong>Sync from repo</strong>
            or run <code class="text-xs">mix tales.sync_docs</code>.
          </p>
        <% else %>
          <ul class="divide-y divide-[var(--paper-rule)]">
            <li
              :for={d <- @decisions}
              class="flex flex-wrap items-center gap-3 py-3"
              id={"decision-#{d.slug}"}
            >
              <div class="flex items-center gap-1">
                <button
                  type="button"
                  phx-click="move_up"
                  phx-value-slug={d.slug}
                  class="rounded px-2 py-1 text-xs border border-[var(--paper-rule)]"
                  title="Move up"
                >
                  ↑
                </button>
                <button
                  type="button"
                  phx-click="move_down"
                  phx-value-slug={d.slug}
                  class="rounded px-2 py-1 text-xs border border-[var(--paper-rule)]"
                  title="Move down"
                >
                  ↓
                </button>
                <span class="play-label w-8 text-center text-[var(--paper-muted)]">{d.rank}</span>
              </div>

              <div class="min-w-0 flex-1">
                <.link
                  navigate={~p"/admin/decisions/#{d.slug}"}
                  class="font-medium text-[var(--paper-ink)] hover:text-[var(--paper-accent)]"
                >
                  {d.title}
                </.link>
                <p class="text-xs text-[var(--paper-muted)]">{d.slug}</p>
              </div>

              <.status_badge status={d.status} />

              <span class="text-xs text-[var(--paper-muted)]">
                {length(d.interests)} interested
              </span>
            </li>
          </ul>
        <% end %>
      </.section_card>
    </Layouts.admin>
    """
  end

  attr :status, :string, required: true

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "rounded-full px-2 py-0.5 text-xs font-medium",
      @status == "open" && "bg-amber-100 text-amber-900",
      @status == "discussing" && "bg-sky-100 text-sky-900",
      @status == "decided" && "bg-emerald-100 text-emerald-900",
      @status == "superseded" && "bg-zinc-200 text-zinc-700"
    ]}>
      {@status}
    </span>
    """
  end
end
