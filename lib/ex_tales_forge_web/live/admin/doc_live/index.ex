defmodule TalesForgeWeb.AdminLive.DocLive.Index do
  @moduledoc """
  Admin: the project docs, rendered from Markdown.

  Every doc has its own URL, `/admin/docs/<path under docs/>` (e.g.
  `/admin/docs/founder-survey-3.md`), so docs can link to each other: relative
  links in a doc are rewritten to those URLs, to decision pages or to GitHub
  (`TalesForge.Collab.Links`).
  """

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
     |> assign(:missing, nil)
     |> assign(:body_html, nil)}
  end

  @impl true
  def handle_params(%{"path" => segments}, _uri, socket) do
    path = "docs/" <> Enum.join(segments, "/")

    case Collab.get_or_fetch_doc(path) do
      nil ->
        # Stay on the doc's URL and say so in the doc's place, never the list.
        {:noreply,
         socket
         |> assign(page_title: "Doc not found", selected: nil, body_html: nil, missing: path)}

      doc ->
        {:noreply,
         socket
         |> assign(:page_title, doc.title)
         |> assign(:missing, nil)
         |> assign(:selected, doc)
         # The card heading already shows the title; don't repeat the doc's own H1.
         |> assign(
           :body_html,
           doc.body |> Markdown.strip_title_heading(doc.title) |> Collab.render_body(doc.path)
         )
         |> push_event("scroll-into-view", %{id: "doc-preview", mobile_only: true})}
    end
  end

  def handle_params(_params, _uri, socket),
    do:
      {:noreply, assign(socket, page_title: "Docs", selected: nil, body_html: nil, missing: nil)}

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    docs = Collab.search_docs(q)
    {:noreply, assign(socket, docs: docs, query: q)}
  end

  @doc "The doc viewer URL of a doc path (`docs/personas.md` -> `/admin/docs/personas.md`)."
  @spec doc_url(String.t()) :: String.t()
  def doc_url(path), do: "/admin/docs/" <> String.replace_prefix(path, "docs/", "")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin
      socket={@socket}
      flash={@flash}
      active="docs"
      page={(@selected && @selected.title) || (@missing && "Not found")}
      wide
    >
      <header class="space-y-1">
        <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">
          {(@selected && @selected.title) || "Shared docs"}
        </h2>
        <p class="text-[var(--paper-muted)]">
          <span :if={@selected} class="font-mono text-xs">{@selected.path} · </span>
          Indexed from the tales-forge-docs repo.
        </p>
      </header>

      <form id="doc-search" phx-change="search" phx-submit="search" class="max-w-md">
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
          open={is_nil(@selected) and is_nil(@missing)}
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

        <%!-- On a phone the doc comes first, the file list after it --%>
        <.section_card
          id="doc-preview"
          title={(@selected && @selected.title) || "Preview"}
          class={[
            "-mx-3 scroll-mt-2 rounded-none border-x-0 px-4 py-5 sm:mx-0 sm:rounded-lg sm:border-x sm:px-6",
            (@selected || @missing) && "max-lg:order-first"
          ]}
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
            <div :if={@missing} id="doc-missing" class="space-y-2 text-sm">
              <p class="text-[var(--paper-ink)]">
                <span class="font-mono">{@missing}</span>
                isn't in the docs index, and GitHub doesn't have it either.
              </p>
              <a
                href={"https://github.com/whyse-ab/tales-forge-docs/blob/main/" <> @missing}
                class="text-[var(--paper-accent)] underline"
              >
                Look for it on GitHub ↗
              </a>
            </div>
            <p :if={!@missing} class="text-sm text-[var(--paper-muted)]">Select a document.</p>
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
        <.link
          patch={doc_url(doc.path)}
          data-path={doc.path}
          class={[
            "block",
            "w-full text-left rounded px-2 py-1.5",
            @selected && @selected.path == doc.path &&
              "bg-[var(--paper-accent)] text-[var(--paper-on-accent)]",
            (!@selected || @selected.path != doc.path) &&
              "hover:bg-[var(--paper-bg)] text-[var(--paper-ink)]"
          ]}
        >
          <span class="block font-medium">{doc.title}</span>
          <span class="block break-all text-xs opacity-75">{doc.path}</span>
        </.link>
      </li>
    </ul>
    <p :if={@docs == []} class="text-sm text-[var(--paper-muted)]">
      No docs indexed yet. Sync from the queue.
    </p>
    """
  end
end
