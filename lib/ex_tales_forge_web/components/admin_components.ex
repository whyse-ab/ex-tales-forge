defmodule TalesForgeWeb.AdminComponents do
  @moduledoc false

  use TalesForgeWeb, :html

  attr :active, :string, default: "dashboard"

  def nav(assigns) do
    ~H"""
    <nav class="-mx-0.5 flex gap-1 overflow-x-auto whitespace-nowrap text-sm lg:mx-0 lg:block lg:space-y-1 lg:overflow-visible lg:whitespace-normal">
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
      <.nav_link href={~p"/admin/oban"} label="Oban / telemetry" active={@active == "oban"} />
      <.nav_link href={~p"/"} label="← Player home" active={false} />
      <.link
        href={~p"/admin/logout"}
        method="delete"
        class="block shrink-0 rounded px-3 py-2 text-[var(--paper-muted)] hover:bg-[var(--paper-panel)]"
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
      class={[
        "block shrink-0 rounded px-3 py-2",
        @active && "bg-[var(--paper-accent)] text-white",
        !@active && "text-[var(--paper-ink)] hover:bg-[var(--paper-panel)]"
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
  def format_ms(ms), do: "#{div(ms, 60_000)} min #{div(rem(ms, 60_000), 1000)} s"
end
