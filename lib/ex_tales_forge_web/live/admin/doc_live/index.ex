defmodule TalesForgeWeb.AdminLive.DocLive.Index do
  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents

  alias TalesForge.Collab
  alias TalesForge.Collab.Markdown

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
     # The card heading already shows the title; don't repeat the doc's own H1.
     |> assign(
       :body_html,
       doc.body |> Markdown.strip_title_heading(doc.title) |> Markdown.to_html()
     )
     |> push_event("scroll-into-view", %{id: "doc-preview", mobile_only: true})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active="docs" wide>
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

      <div class="grid gap-4 lg:grid-cols-[18rem_minmax(0,1fr)]">
        <%!-- Small screens: collapsible file list that closes once a doc is picked --%>
        <details
          id="doc-files-mobile"
          class="min-w-0 rounded-lg border border-[var(--paper-rule)] bg-[var(--paper-panel)] lg:hidden"
          open={is_nil(@selected)}
        >
          <summary class="flex cursor-pointer items-center justify-between gap-3 px-3 py-2.5 text-sm">
            <span class="font-serif font-semibold text-[var(--paper-ink)]">
              Files
              <span class="font-sans font-normal text-[var(--paper-muted)]">({length(@docs)})</span>
            </span>
            <span :if={@selected} class="truncate text-xs text-[var(--paper-muted)]">
              {@selected.path}
            </span>
          </summary>
          <div class="border-t border-[var(--paper-rule)] p-2">
            <.doc_list docs={@docs} selected={@selected} />
          </div>
        </details>

        <%!-- Desktop: sticky, independently scrolling file list, so the column
             stays populated next to a long doc instead of going blank --%>
        <.section_card
          title="Files"
          class="hidden lg:sticky lg:top-4 lg:block lg:max-h-[calc(100dvh-2rem)] lg:self-start lg:overflow-y-auto"
        >
          <.doc_list docs={@docs} selected={@selected} />
        </.section_card>

        <.section_card
          id="doc-preview"
          title={(@selected && @selected.title) || "Preview"}
          class="-mx-3 scroll-mt-2 rounded-none border-x-0 px-4 py-5 sm:mx-0 sm:rounded-lg sm:border-x sm:px-6"
        >
          <%= if @selected do %>
            <%!-- id changes per doc + phx-update="ignore": LiveView swaps the whole
                 element on selection, so the Mermaid hook's SVGs are not patched away --%>
            <article
              id={"doc-body-#{@selected.id}-#{:erlang.phash2(@selected.body)}"}
              phx-hook="Mermaid"
              phx-update="ignore"
              class="prose prose-sm max-w-[80ch] text-[var(--paper-ink)]"
            >
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

  attr :docs, :list, required: true
  attr :selected, :any, default: nil

  defp doc_list(assigns) do
    ~H"""
    <ul class="space-y-1 text-sm">
      <li :for={doc <- @docs}>
        <button
          type="button"
          phx-click="select"
          phx-value-path={doc.path}
          class={[
            "w-full text-left rounded px-2 py-1.5",
            @selected && @selected.path == doc.path && "bg-[var(--paper-accent)] text-white",
            (!@selected || @selected.path != doc.path) &&
              "hover:bg-[var(--paper-bg)] text-[var(--paper-ink)]"
          ]}
        >
          <span class="block font-medium">{doc.title}</span>
          <span class="block break-all text-xs opacity-75">{doc.path}</span>
        </button>
      </li>
    </ul>
    <p :if={@docs == []} class="text-sm text-[var(--paper-muted)]">
      No docs indexed yet. Sync from the queue.
    </p>
    """
  end
end
