defmodule TalesForgeWeb.AdminLive.DashboardLive do
  @moduledoc """
  The admin home (`/admin`): one card per section of the admin area
  (`TalesForgeWeb.AdminSections`: Founders, Play and test, Operate, Develop,
  Docs), each with a one-line summary and links to its pages, then the
  collapsed Archive and the game database at a glance.
  """

  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents

  alias TalesForge.Admin
  alias TalesForge.AppRole
  alias TalesForgeWeb.AdminSections

  @impl true
  def mount(_params, _session, socket) do
    sections = AdminSections.sections()

    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> assign(:role, AppRole.role())
     |> assign(:sections, Enum.reject(sections, &(&1.id == :archive)))
     |> assign(:archive, Enum.find(sections, &(&1.id == :archive)))
     |> assign(:stats, Admin.stats())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active="dashboard">
      <header class="space-y-1">
        <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">Admin home</h2>
        <p class="text-[var(--paper-muted)]">
          Everything behind the team sign-in, grouped by what it is for.
        </p>
      </header>

      <div id="admin-sections" class="grid gap-3 sm:grid-cols-2 xl:grid-cols-3">
        <section
          :for={section <- @sections}
          id={"section-#{section.id}"}
          aria-labelledby={"section-#{section.id}-title"}
          class="min-w-0 rounded-lg border border-[var(--paper-rule)] bg-[var(--paper-panel)] p-4"
        >
          <h3
            id={"section-#{section.id}-title"}
            class="font-serif text-lg font-semibold text-[var(--paper-ink)]"
          >
            {section.title}
          </h3>
          <p class="mt-0.5 text-sm text-[var(--paper-muted)]">{section.line}</p>
          <.section_links items={section.items} role={@role} />
        </section>
      </div>

      <details
        id="section-archive"
        class="rounded-lg border border-[var(--paper-rule)] bg-[var(--paper-panel)] p-4"
      >
        <summary class="min-h-11 cursor-pointer font-serif text-lg font-semibold text-[var(--paper-ink)]">
          {@archive.title}
          <span class="font-sans text-sm font-normal text-[var(--paper-muted)]">
            {@archive.line}
          </span>
        </summary>
        <.section_links items={@archive.items} role={@role} />
      </details>

      <section id="at-a-glance" aria-labelledby="at-a-glance-title" class="space-y-2">
        <h3 id="at-a-glance-title" class="play-label text-[var(--paper-muted)]">
          The game database at a glance
        </h3>
        <div class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
          <.stat_card label="Sessions" value={@stats.sessions} />
          <.stat_card label="Active sessions" value={@stats.active_sessions} />
          <.stat_card label="Turns" value={@stats.turns} />
          <.stat_card label="NPC instances" value={@stats.npc_instances} />
          <.stat_card label="Scenes" value={@stats.scenes} />
        </div>
      </section>
    </Layouts.admin>
    """
  end

  attr :items, :list, required: true
  attr :role, :atom, required: true

  defp section_links(assigns) do
    ~H"""
    <ul class="mt-2 -mx-1 flex flex-wrap gap-x-1 text-sm">
      <li :for={item <- @items} class="min-w-0">
        <.link
          navigate={
            if item.kind == :live and not AdminSections.elsewhere?(item, @role),
              do: AdminSections.href(item, @role)
          }
          href={
            if item.kind != :live or AdminSections.elsewhere?(item, @role),
              do: AdminSections.href(item, @role)
          }
          target={item.kind == :external && "_blank"}
          rel={item.kind == :external && "noopener noreferrer"}
          class="inline-flex min-h-11 items-center rounded px-1 text-[var(--paper-accent)] underline-offset-2 hover:underline"
        >
          {link_label(item, @role)}
        </.link>
      </li>
    </ul>
    """
  end

  defp link_label(item, role) do
    cond do
      AdminSections.elsewhere?(item, role) -> "#{item.label} (#{AppRole.home_label(item.area)}) ↗"
      item.kind == :external -> item.label <> " ↗"
      true -> item.label
    end
  end
end
