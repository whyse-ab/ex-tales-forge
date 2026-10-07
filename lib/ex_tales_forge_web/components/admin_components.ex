defmodule TalesForgeWeb.AdminComponents do
  @moduledoc false

  use TalesForgeWeb, :html

  attr :active, :string, default: "dashboard"

  def nav(assigns) do
    ~H"""
    <%!-- Phones: one row that scrolls sideways; the AdminNav hook scrolls the
         active tab fully into view and fades whichever edge has more tabs.
         Desktop: a plain vertical list. --%>
    <nav
      id="admin-nav"
      phx-hook="AdminNav"
      aria-label="Admin sections"
      class="admin-nav -mx-0.5 flex gap-1 overflow-x-auto whitespace-nowrap text-sm lg:mx-0 lg:block lg:space-y-1 lg:overflow-visible lg:whitespace-normal"
    >
      <.nav_link href={~p"/admin"} label="Dashboard" active={@active == "dashboard"} />
      <.nav_link href={~p"/admin/decisions"} label="Decisions" active={@active == "decisions"} />
      <.nav_link href={~p"/admin/docs"} label="Docs" active={@active == "docs"} />
      <.nav_link href={~p"/admin/sessions"} label="Sessions" active={@active == "sessions"} />
      <.nav_link href={~p"/admin/playtest"} label="Playtest runs" active={@active == "playtest"} />
      <.nav_link
        href={~p"/admin/npc-definitions"}
        label="NPC definitions"
        active={@active == "npc_definitions"}
      />
      <.nav_link href={~p"/admin/costs"} label="Costs" active={@active == "costs"} />
      <.nav_link href={~p"/admin/oban"} label="Oban / telemetry" active={@active == "oban"} />
      <.nav_link href={~p"/"} label="← Player home" active={false} />
      <.link
        href={~p"/admin/logout"}
        method="delete"
        class="block shrink-0 rounded px-3 py-2 text-[var(--paper-muted)] hover:bg-[var(--paper-bg)]"
      >
        Sign out
      </.link>
    </nav>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      aria-current={@active && "page"}
      class={[
        "block shrink-0 rounded px-3 py-2",
        @active && "bg-[var(--paper-accent)] text-[var(--paper-on-accent)]",
        !@active && "text-[var(--paper-ink)] hover:bg-[var(--paper-bg)]"
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
