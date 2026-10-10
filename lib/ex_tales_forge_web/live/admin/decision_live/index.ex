defmodule TalesForgeWeb.AdminLive.DecisionLive.Index do
  @moduledoc """
  Admin: the founder decision queue; updates live. Read-only once the open
  items are imported into the idea board on `/team` (`Collab.read_only?/0`):
  no reordering, a notice links to the board.
  """

  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents

  alias TalesForge.Collab

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Collab.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Decision queue")
     |> assign(:decisions, Collab.list_decisions())
     |> assign(:read_only, Collab.read_only?())
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
  def handle_event(event, _params, %{assigns: %{read_only: true}} = socket)
      when event in ["move_up", "move_down"] do
    {:noreply, put_flash(socket, :error, read_only_message())}
  end

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

  @doc false
  @spec read_only_message() :: String.t()
  def read_only_message,
    do: "The decision queue is read-only: its open items moved to the idea board on /team."

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
    <Layouts.admin socket={@socket} flash={@flash} active="decisions">
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

      <p
        :if={@read_only}
        id="decisions-read-only"
        class="rounded border border-[var(--paper-rule)] bg-[var(--paper-info-bg)] p-3 text-sm text-[var(--paper-info-ink)]"
      >
        Read-only: the open items now live on the <.link
          navigate={~p"/team#idea-board"}
          class="underline"
        >founders' idea board</.link>.
      </p>

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
                  :if={!@read_only}
                  type="button"
                  phx-click="move_up"
                  phx-value-slug={d.slug}
                  class="rounded px-2 py-1 text-xs border border-[var(--paper-rule)]"
                  title="Move up"
                >
                  ↑
                </button>
                <button
                  :if={!@read_only}
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
                  navigate={~p"/admin/founders/decisions/#{d.slug}"}
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
      @status == "open" && "bg-[var(--paper-warn-bg)] text-[var(--paper-warn-ink)]",
      @status == "discussing" && "bg-[var(--paper-info-bg)] text-[var(--paper-info-ink)]",
      @status == "decided" && "bg-[var(--paper-ok-bg)] text-[var(--paper-ok-ink)]",
      @status == "superseded" && "bg-[var(--paper-quiet-bg)] text-[var(--paper-quiet-ink)]"
    ]}>
      {@status}
    </span>
    """
  end
end
