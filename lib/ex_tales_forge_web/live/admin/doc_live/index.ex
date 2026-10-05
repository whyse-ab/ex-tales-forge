defmodule TalesForgeWeb.AdminLive.DocLive.Index do
  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents

  alias TalesForge.Collab
  alias TalesForge.Collab.Markdown

  on_mount {TalesForgeWeb.AdminLive.Hooks, :require_admin}

  @impl true
  def mount(_params, _session, socket) do
    docs = Collab.list_docs()

    {:ok,
     socket
     |> assign(:page_title, "Docs")
     |> assign(:docs, docs)
     |> assign(:query, "")
     |> assign(:selected, nil)
     |> assign(:body_html, nil)}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    docs = Collab.search_docs(q)
    {:noreply, assign(socket, docs: docs, query: q)}
  end

  def handle_event("select", %{"path" => path}, socket) do
    doc = Collab.get_doc_by_path!(path)

    {:noreply,
     socket
     |> assign(:selected, doc)
     |> assign(:body_html, Markdown.to_html(doc.body))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active="docs">
      <header class="space-y-1">
        <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">Shared docs</h2>
        <p class="text-[var(--paper-muted)]">Indexed from the tales-forge-docs repo.</p>
      </header>

      <form phx-change="search" phx-submit="search" class="max-w-md">
        <input
          type="search"
          name="q"
          value={@query}
          placeholder="Search docs…"
          class="w-full rounded border border-[var(--paper-rule)] bg-[var(--paper-bg)] px-3 py-2 text-sm"
        />
      </form>

      <div class="grid gap-4 lg:grid-cols-[18rem_1fr]">
        <.section_card title="Files">
          <ul class="space-y-1 text-sm">
            <li :for={doc <- @docs}>
              <button
                type="button"
                phx-click="select"
                phx-value-path={doc.path}
                class={[
                  "w-full text-left rounded px-2 py-1",
                  @selected && @selected.path == doc.path && "bg-[var(--paper-accent)] text-white",
                  (!@selected || @selected.path != doc.path) &&
                    "hover:bg-[var(--paper-bg)] text-[var(--paper-ink)]"
                ]}
              >
                <span class="block font-medium">{doc.title}</span>
                <span class="block text-xs opacity-75">{doc.path}</span>
              </button>
            </li>
          </ul>
          <%= if @docs == [] do %>
            <p class="text-sm text-[var(--paper-muted)]">No docs indexed yet. Sync from the queue.</p>
          <% end %>
        </.section_card>

        <.section_card title={(@selected && @selected.title) || "Preview"}>
          <%= if @selected do %>
            <article class="prose prose-sm max-w-none text-[var(--paper-ink)]">
              {@body_html}
            </article>
          <% else %>
            <p class="text-sm text-[var(--paper-muted)]">Select a document.</p>
          <% end %>
        </.section_card>
      </div>
    </Layouts.admin>
    """
  end
end
