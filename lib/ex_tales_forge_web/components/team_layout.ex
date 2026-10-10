defmodule TalesForgeWeb.TeamLayout do
  @moduledoc """
  The frame shared by the two founders' pages, the landing page at `/team`
  (`TalesForgeWeb.TeamLive`) and the full presentation at `/team/presentation`
  (`TalesForgeWeb.TeamPresentationLive`): the sticky header with its in-page
  nav, and the "Numbers as of" footer.

  The in-page nav wraps onto a second (or third) line on a phone instead of
  running off the side: Gentry measured the presentation's sub-nav at about
  568 px on a 390 px phone when it was one unbroken row. Nothing in it scrolls
  sideways, so the page never does either.
  """

  use TalesForgeWeb, :html

  import TalesForge.TeamPage, only: [get: 2, date_label: 1]

  alias TalesForge.TeamPage

  @typedoc "An in-page nav entry: the anchor (an element id) and its label."
  @type nav_item :: {String.t(), String.t()}

  @doc """
  The sticky header: the Tales Forge link, Admin and the theme toggle, then the
  in-page nav. `page` is the page being shown (`:landing` or `:presentation`);
  `items` are the `{anchor, label}` pairs of that page. The presentation's nav
  starts with the way back to the overview; the landing page links the
  presentation once, from its own card (`#presentation-cta`).
  """
  attr :page, :atom, required: true, values: [:landing, :presentation]
  attr :items, :list, required: true, doc: "`{anchor, label}` pairs"

  attr :socket, :any,
    default: nil,
    doc: "with it, who is online (`TalesForgeWeb.OnlineHeaderLive`)"

  @spec header(map()) :: Phoenix.LiveView.Rendered.t()
  def header(assigns) do
    ~H"""
    <header
      id="team-header"
      class="z-30 border-b sm:sticky sm:top-0 border-[var(--paper-rule)] bg-[var(--paper-panel)]/95 backdrop-blur"
    >
      <div class="mx-auto flex max-w-6xl items-center justify-between gap-3 px-3 py-2 sm:px-6">
        <.link navigate={~p"/"} class="font-serif text-base font-semibold sm:text-lg">Tales Forge</.link>
        <div class="flex flex-wrap items-center justify-end gap-2 sm:gap-3">
          {@socket &&
            live_render(@socket, TalesForgeWeb.OnlineHeaderLive,
              id: "team-online",
              session: %{"id_prefix" => "team-online"}
            )}
          <TalesForgeWeb.AppComponents.env_badge id="team-env-badge" />
          <.link
            href={~p"/admin"}
            class="text-sm text-[var(--paper-muted)] hover:text-[var(--paper-accent)] hover:underline"
          >
            Admin
          </.link>
          <Layouts.theme_toggle />
        </div>
      </div>
      <nav id="team-nav" aria-label="Page sections" class="mx-auto max-w-6xl px-2 pb-2 sm:px-4">
        <ul
          id="team-nav-list"
          class="flex flex-wrap items-center gap-x-0.5 gap-y-0.5 text-[0.8rem] sm:gap-x-1 sm:text-sm"
        >
          <li :if={@page == :presentation}>
            <.link
              id="team-nav-overview"
              navigate={~p"/team"}
              class="team-nav-home block rounded px-1.5 py-0.5 font-semibold sm:px-2.5 sm:py-1"
            >
              ← Overview
            </.link>
          </li>
          <li :for={{id, label} <- @items}>
            <a
              href={"##{id}"}
              class="block rounded px-1.5 py-0.5 text-[var(--paper-muted)] hover:bg-[var(--paper-bg)] hover:text-[var(--paper-ink)] sm:px-2.5 sm:py-1"
            >
              {label}
            </a>
          </li>
        </ul>
      </nav>
    </header>
    """
  end

  @doc "The footer: the date the numbers are from, and where they come from."
  attr :d, :map, required: true

  @spec footer(map()) :: Phoenix.LiveView.Rendered.t()
  def footer(assigns) do
    ~H"""
    <footer
      id="team-footer"
      class="border-t border-[var(--paper-rule)] bg-[var(--paper-panel)] px-4 py-6 text-center text-sm text-[var(--paper-muted)]"
    >
      <p>Bundled numbers as of {date_label(get(@d, ["_about", "as_of"]))}</p>
      <p class="mt-1 text-xs">
        Pull requests, commits, tests, decisions, AI spend, Jev latency and persona scores come live (from GitHub and from the app) when a source is up.
        Each group says “live” or “as of” its date. The other numbers come from
        <code>docs/team-page/data.json</code>
        in tales-forge-docs. Where we have no number, it says “{TeamPage.not_measured()}”.
      </p>
    </footer>
    """
  end
end
