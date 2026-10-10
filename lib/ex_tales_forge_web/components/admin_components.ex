defmodule TalesForgeWeb.AdminComponents do
  @moduledoc false

  use TalesForgeWeb, :html

  alias TalesForge.AppRole
  alias TalesForgeWeb.AdminSections
  alias TalesForgeWeb.TimeAgo

  attr :active, :string, default: "dashboard"

  @doc """
  The admin nav, grouped by purpose (`TalesForgeWeb.AdminSections`): Admin
  home, then Founders, Play and test, Operate, Develop and Docs, a collapsed
  Archive, and Player home and Sign out.

  Phones and tablets (below `lg`) get one "Menu" row that names the current
  page and opens the groups (a `<details>`, no JavaScript); from `lg` up it is
  the always-open sidebar list (the summary is hidden and the content shown
  with `::details-content`; a browser without it keeps the Menu button).
  `active` names the current page (an item's `key`), marked with
  `aria-current="page"`.
  """
  @spec nav(map()) :: Phoenix.LiveView.Rendered.t()
  def nav(assigns) do
    section = AdminSections.section_of(assigns.active)

    assigns =
      assigns
      |> assign(:role, AppRole.role())
      |> assign(:groups, Enum.reject(AdminSections.sections(), &(&1.id == :archive)))
      |> assign(:archive, Enum.find(AdminSections.sections(), &(&1.id == :archive)))
      |> assign(:current, current_label(section, assigns.active))
      |> assign(:in_archive, match?(%{id: :archive}, section))

    ~H"""
    <style>
      @media (min-width: 64rem) {
        @supports selector(::details-content) {
          #admin-nav-menu > summary { display: none; }
          #admin-nav-menu::details-content { content-visibility: visible; display: block; }
        }
      }
    </style>
    <nav id="admin-nav" aria-label="Admin sections" class="admin-nav text-sm">
      <details id="admin-nav-menu" class="group/menu">
        <summary
          aria-label="Admin menu"
          class="flex min-h-11 cursor-pointer list-none items-center justify-between gap-3 rounded px-2.5 py-1.5 text-[var(--paper-ink)] hover:bg-[var(--paper-bg)] [&::-webkit-details-marker]:hidden"
        >
          <span class="font-semibold">Menu</span>
          <span class="min-w-0 truncate text-[var(--paper-muted)]" aria-hidden="true">
            {@current}
            <span aria-hidden="true" class="ml-1 inline-block group-open/menu:rotate-180">▾</span>
          </span>
        </summary>
        <div class="space-y-3 px-1 pt-2 pb-1 lg:p-0">
          <.nav_link href={~p"/admin"} label="Admin home" active={@active == "dashboard"} />
          <div :for={group <- @groups} id={"admin-nav-#{group.id}"} data-group={group.id}>
            <p class="play-label px-2.5 pb-1 text-[var(--paper-muted)] lg:px-3">{group.title}</p>
            <ul class="grid grid-cols-2 gap-0.5 lg:block lg:space-y-0.5">
              <li :for={item <- Enum.filter(group.items, & &1[:nav])}>
                <.section_link item={item} role={@role} active={@active} />
              </li>
            </ul>
          </div>
          <details
            id="admin-nav-archive"
            data-group="archive"
            open={@in_archive}
            class="border-t border-[var(--paper-rule)] pt-2"
          >
            <summary class="play-label min-h-11 cursor-pointer px-2.5 py-2 text-[var(--paper-muted)] lg:px-3">
              Archive
            </summary>
            <ul class="grid grid-cols-2 gap-0.5 lg:block">
              <li :for={item <- @archive.items}>
                <.section_link item={item} role={@role} active={@active} />
              </li>
            </ul>
          </details>
          <div class="grid grid-cols-2 gap-0.5 border-t border-[var(--paper-rule)] pt-2 lg:block">
            <.nav_link href={~p"/"} label="← Player home" active={false} />
            <.link
              href={~p"/admin/logout"}
              method="delete"
              class="block min-h-11 rounded px-2.5 py-2.5 text-[var(--paper-muted)] hover:bg-[var(--paper-bg)] lg:min-h-0 lg:px-3 lg:py-1.5"
            >
              Sign out
            </.link>
          </div>
        </div>
      </details>
    </nav>
    """
  end

  defp current_label(nil, "dashboard"), do: "Admin home"
  defp current_label(nil, _active), do: "All pages"

  defp current_label(section, active) do
    case Enum.find(section.items, &(&1[:key] == active)) do
      nil -> section.title
      item -> section.title <> " · " <> item.label
    end
  end

  attr :item, :map, required: true, doc: "a TalesForgeWeb.AdminSections item"
  attr :role, :atom, required: true
  attr :active, :string, default: nil

  @doc """
  A link to one `TalesForgeWeb.AdminSections` item: `navigate` for a LiveView
  in the admin live session, a plain `href` for any other page, a new tab for
  another site, and the full URL with the app's name for a page that lives on
  the other app (`TalesForge.AppRole`).
  """
  @spec section_link(map()) :: Phoenix.LiveView.Rendered.t()
  def section_link(assigns) do
    item = assigns.item
    elsewhere = AdminSections.elsewhere?(item, assigns.role)

    assigns =
      assign(assigns,
        href: AdminSections.href(item, assigns.role),
        label: AdminSections.link_label(item, assigns.role),
        cross_app: AdminSections.cross_app?(item, assigns.role),
        external: elsewhere or item.kind != :live,
        new_tab: item.kind == :external,
        current: not elsewhere and item[:key] != nil and item[:key] == assigns.active
      )

    ~H"""
    <.nav_link
      href={@href}
      label={@label}
      active={@current}
      external={@external}
      new_tab={@new_tab}
      cross_app={@cross_app}
    />
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :external, :boolean, default: false, doc: "non-LiveView page: plain href"
  attr :new_tab, :boolean, default: false, doc: "another site: opens in a new tab"
  attr :cross_app, :boolean, default: false, doc: "belongs to the other app: highlighted"

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={if !@external, do: @href}
      href={if @external, do: @href}
      target={@new_tab && "_blank"}
      rel={@new_tab && "noopener noreferrer"}
      aria-current={@active && "page"}
      aria-label={@label}
      data-cross-app={@cross_app}
      class={[
        "block min-h-11 rounded px-2.5 py-2.5 leading-snug lg:min-h-0 lg:px-3 lg:py-1.5",
        @active && "bg-[var(--paper-accent)] text-[var(--paper-on-accent)]",
        !@active && !@cross_app && "text-[var(--paper-ink)] hover:bg-[var(--paper-bg)]",
        !@active && @cross_app &&
          "font-semibold text-[var(--paper-accent)] hover:bg-[var(--paper-bg)]"
      ]}
    >
      {@label}
    </.link>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  def stat_card(assigns) do
    ~H"""
    <div class="rounded-lg border border-[var(--paper-rule)] bg-[var(--paper-panel)] p-4">
      <p class="play-label text-[var(--paper-muted)]">{@label}</p>
      <p class="mt-1 font-serif text-2xl font-bold text-[var(--paper-ink)]">{@value}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :rows, :integer, default: 18

  def json_editor(assigns) do
    ~H"""
    <div class="space-y-2">
      <label for={@id} class="play-label text-[var(--paper-muted)]">{@label}</label>
      <textarea
        id={@id}
        name={@id}
        rows={@rows}
        class="w-full rounded border border-[var(--paper-rule)] bg-[var(--paper-bg)] p-3 font-mono text-sm text-[var(--paper-ink)]"
      >{@value}</textarea>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def section_card(assigns) do
    ~H"""
    <section
      id={@id}
      class={[
        "min-w-0 rounded-lg border border-[var(--paper-rule)] bg-[var(--paper-panel)] p-3 sm:p-4 space-y-3",
        @class
      ]}
    >
      <h2 class="font-serif text-lg font-semibold text-[var(--paper-ink)]">{@title}</h2>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :at, DateTime, required: true, doc: "the instant to describe"

  attr :now, DateTime,
    required: true,
    doc: "the render's \"now\"; tick it to keep the words fresh"

  attr :id, :string, default: nil

  @doc """
  How long ago `at` was ("3 minutes ago"), as a `<time>` element whose
  `title` tooltip is the absolute time in Europe/Stockholm. See
  `TalesForgeWeb.TimeAgo`.
  """
  @spec time_ago(map()) :: Phoenix.LiveView.Rendered.t()
  def time_ago(assigns) do
    ~H"""
    <time
      id={@id}
      datetime={DateTime.to_iso8601(@at)}
      title={TimeAgo.stockholm(@at)}
    >{TimeAgo.relative(@at, @now)}</time>
    """
  end

  def format_usd(nil), do: "—"

  def format_usd(micro_usd),
    do: "$" <> :erlang.float_to_binary(micro_usd / 1_000_000, decimals: 4)

  def format_ms(nil), do: "—"
  def format_ms(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)} s"
  def format_ms(ms) when is_float(ms), do: format_ms(round(ms))
  def format_ms(ms), do: "#{div(ms, 60_000)} min #{div(rem(ms, 60_000), 1000)} s"

  def format_latency(nil), do: "—"
  def format_latency(ms) when ms < 1_000, do: "#{round(ms)} ms"
  def format_latency(ms), do: :erlang.float_to_binary(ms / 1_000, decimals: 2) <> " s"

  def format_pct(nil), do: "—"
  def format_pct(ratio), do: :erlang.float_to_binary(ratio * 100, decimals: 1) <> "%"

  @section_labels %{"game" => "Game", "persona" => "Persona (bot)", "scorer" => "Scorer (bot)"}

  @doc """
  Table of `TalesForge.AICalls.Metrics` breakdown rows: one block per section
  (game, then the persona and scorer bots, never summed together), one row per
  call_type and purpose with count, total and average cost, per-session and
  per-turn cost (when the rows carry them) and p50/p90 latency.
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :per_session, :boolean, default: false

  def call_breakdown(assigns) do
    assigns =
      assign(assigns, :sections, Enum.chunk_by(assigns.rows, & &1.section))

    ~H"""
    <div class="min-w-0 overflow-x-auto">
      <table id={@id} class="w-full text-sm">
        <thead class="text-left text-[var(--paper-muted)]">
          <tr>
            <th class="py-1 pr-2 font-medium">Type · purpose</th>
            <th class="py-1 pr-2 text-right font-medium">Calls</th>
            <th class="py-1 pr-2 text-right font-medium">Total</th>
            <th class="hidden py-1 pr-2 text-right font-medium sm:table-cell">Avg</th>
            <th
              :if={@per_session}
              class="hidden py-1 pr-2 text-right font-medium md:table-cell"
            >
              /session
            </th>
            <th class="hidden py-1 pr-2 text-right font-medium sm:table-cell">/turn</th>
            <th class="py-1 pr-2 text-right font-medium">p50</th>
            <th class="hidden py-1 text-right font-medium sm:table-cell">p90</th>
          </tr>
        </thead>
        <tbody :for={rows <- @sections} id={"#{@id}-#{hd(rows).section}"}>
          <tr class="border-t border-[var(--paper-rule)]">
            <th
              colspan="8"
              scope="colgroup"
              class="play-label pt-2 pb-1 text-left text-[var(--paper-muted)]"
            >
              {section_label(hd(rows).section)}
            </th>
          </tr>
          <tr :for={row <- rows} id={row_id(@id, row)}>
            <td class="py-1 pr-2">
              <span class={[
                "mr-1 rounded px-1 text-xs",
                row.call_type == "function" && "bg-[var(--paper-bg)] text-[var(--paper-muted)]",
                row.call_type != "function" && "bg-[var(--paper-bg)] text-[var(--paper-ink)]"
              ]}>
                {row.call_type}
              </span>
              {row.purpose}
            </td>
            <td class="py-1 pr-2 text-right tabular-nums">{row.calls}</td>
            <td class="whitespace-nowrap py-1 pr-2 text-right tabular-nums">
              {format_usd(row.cost_micro_usd)}
            </td>
            <td class="hidden whitespace-nowrap py-1 pr-2 text-right tabular-nums sm:table-cell">
              {format_usd(row.avg_cost_micro_usd)}
            </td>
            <td
              :if={@per_session}
              class="hidden whitespace-nowrap py-1 pr-2 text-right tabular-nums md:table-cell"
            >
              {format_usd(row[:per_session_micro_usd])}
            </td>
            <td class="hidden whitespace-nowrap py-1 pr-2 text-right tabular-nums sm:table-cell">
              {format_usd(row[:per_turn_micro_usd])}
            </td>
            <td class="whitespace-nowrap py-1 pr-2 text-right tabular-nums">
              {format_latency(row.p50_ms)}
            </td>
            <td class="hidden whitespace-nowrap py-1 text-right tabular-nums sm:table-cell">
              {format_latency(row.p90_ms)}
            </td>
          </tr>
          <tr id={"#{@id}-#{hd(rows).section}-total"} class="font-semibold">
            <td class="py-1 pr-2">{section_label(hd(rows).section)} total</td>
            <td class="py-1 pr-2 text-right tabular-nums">{section_calls(rows)}</td>
            <td class="whitespace-nowrap py-1 pr-2 text-right tabular-nums">
              {format_usd(section_cost(rows))}
            </td>
            <td colspan="5"></td>
          </tr>
        </tbody>
      </table>
      <p :if={@rows == []} class="text-sm text-[var(--paper-muted)]">No calls recorded.</p>
    </div>
    """
  end

  defp section_label(section), do: Map.get(@section_labels, section, section)

  defp row_id(id, row),
    do: "#{id}-#{row.section}-#{row.call_type}-#{String.replace(row.purpose, ".", "_")}"

  # Function rows are free timed steps, not calls: left out of the call count.
  defp section_calls(rows),
    do: rows |> Enum.reject(&(&1.call_type == "function")) |> Enum.map(& &1.calls) |> Enum.sum()

  defp section_cost(rows), do: rows |> Enum.map(& &1.cost_micro_usd) |> Enum.sum()
end
