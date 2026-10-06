defmodule TalesForgeWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use TalesForgeWeb, :html

  import TalesForgeWeb.AdminComponents

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="paper-home min-h-dvh">
      <header class="border-b border-[var(--paper-rule)] bg-[var(--paper-panel)] px-3 py-3 sm:px-6">
        <div class="mx-auto flex max-w-3xl items-center justify-between gap-4">
          <.link navigate={~p"/"} class="font-serif text-lg font-semibold text-[var(--paper-ink)]">
            Tales Forge
          </.link>
          <div class="flex items-center gap-3">
            <.link
              href={~p"/admin"}
              class="text-sm text-[var(--paper-muted)] hover:text-[var(--paper-accent)] hover:underline"
            >
              Admin
            </.link>
            <.theme_toggle />
          </div>
        </div>
      </header>

      <main class="px-4 py-10 sm:px-6">
        <div class="mx-auto max-w-3xl space-y-4">
          {render_slot(@inner_block)}
        </div>
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :flash, :map, required: true

  slot :inner_block, required: true

  attr :active, :string, default: "dashboard"

  attr :wide, :boolean,
    default: false,
    doc: "wider page (max-w-7xl) for pages with their own sidebar column, e.g. docs"

  def admin(assigns) do
    ~H"""
    <%!-- .admin-shell opts the page into the theme toggle (paper palettes in app.css) --%>
    <div class="admin-shell paper-home min-h-dvh">
      <header class="border-b border-[var(--paper-rule)] bg-[var(--paper-panel)] px-3 py-3 sm:px-6">
        <div class={["mx-auto flex items-center justify-between", admin_width(@wide)]}>
          <div>
            <p class="play-label text-[var(--paper-accent)]">Tales Forge</p>
            <h1 class="font-serif text-lg font-semibold text-[var(--paper-ink)]">Admin</h1>
          </div>
          <.theme_toggle />
        </div>
      </header>

      <div class={[
        "mx-auto grid gap-4 px-3 py-4 sm:gap-6 sm:px-6 sm:py-8 lg:grid-cols-[12rem_minmax(0,1fr)]",
        admin_width(@wide)
      ]}>
        <%!-- Sticky on desktop so the nav column doesn't turn into blank space on long pages --%>
        <aside class="min-w-0 rounded-lg border border-[var(--paper-rule)] bg-[var(--paper-panel)] p-1.5 lg:sticky lg:top-4 lg:self-start lg:p-3">
          <.nav active={@active} />
        </aside>
        <main class="min-w-0 space-y-4">
          {render_slot(@inner_block)}
        </main>
      </div>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  defp admin_width(true), do: "max-w-7xl"
  defp admin_width(false), do: "max-w-6xl"

  def play(assigns) do
    ~H"""
    <div class="play-shell flex h-dvh flex-col overflow-hidden">
      {render_slot(@inner_block)}
      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
