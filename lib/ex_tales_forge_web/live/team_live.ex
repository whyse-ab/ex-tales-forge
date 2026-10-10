defmodule TalesForgeWeb.TeamLive do
  @moduledoc """
  The founders' landing page at `/team`, top to bottom:

  1. the compact shared-workspace header with quick stats
     (`TalesForgeWeb.TeamWorkspace`; the crew picture and how we work live on
     `/team/presentation`);
  2. **What we're going to do** (`#idea-board`): the founders' idea board
     (`TalesForgeWeb.TeamIdeaBoard`, live over `TalesForge.Board`'s PubSub) on
     production and locally. `/team` lives on production only
     (`TalesForge.AppRole`, area `:board`): playtest redirects it there;
  3. **What we're doing now** (`#live`): the live GitHub PR, CI and deploy feed,
     the nested `TalesForgeWeb.TeamPrFeedLive` (`TalesForge.PrFeed`, polled on
     the server and pushed over PubSub);
  4. the one link to the full presentation (`#presentation-cta`).

  The crew cards moved to the presentation (decision 2026-10-10). Old links
  still work: the `TeamAnchorRedirect` hook (`assets/js/team_hooks.js`)
  replaces `/team#playtests` and the other
  `TalesForgeWeb.TeamPresentationLive.anchors/0` with the same anchor on the
  presentation, and the old crew anchors (`aliases/0`, e.g. `#crew`,
  `#crew-case`) with the crew on the presentation.

  Behind the GitHub team sign-in like every page (router `:browser` pipeline
  plus the `:require_team_member` mount hook). Read-only; copy follows
  tales-forge-docs `docs/team-page/content.md`; numbers come from
  `TalesForge.TeamPage`.
  """

  use TalesForgeWeb, :live_view

  alias TalesForge.PrFeed
  alias TalesForge.TeamPage
  alias TalesForgeWeb.Layouts
  alias TalesForgeWeb.TeamLayout
  alias TalesForgeWeb.TeamPresentationLive
  alias TalesForgeWeb.TeamPrFeed
  alias TalesForgeWeb.TeamWorkspace

  @nav [
    {"idea-board", "Going to do"},
    {"live", "Doing now"},
    {"presentation-cta", "Presentation"}
  ]

  @doc """
  This page's own anchors (its nav and sections). None of them is a
  presentation anchor, so the redirect hook leaves them alone.

      iex> TalesForgeWeb.TeamLive.anchors()
      ["idea-board", "live", "presentation-cta", "workspace"]
  """
  @spec anchors() :: [String.t()]
  def anchors, do: Enum.map(@nav, &elem(&1, 0)) ++ ~w(workspace)

  @doc """
  The old crew anchors of this page and where they land now: the crew on the
  presentation (the section, or that member's card).

      iex> TalesForgeWeb.TeamLive.aliases()["crew"]
      "/team/presentation#team"
      iex> TalesForgeWeb.TeamLive.aliases()["crew-case"]
      "/team/presentation#member-case"
  """
  @spec aliases() :: %{String.t() => String.t()}
  def aliases do
    members = ~w(founders case bobby gentry)

    Map.new(
      [{"crew", "/team/presentation#team"}, {"crew-cards", "/team/presentation#team"}] ++
        Enum.map(members, &{"crew-" <> &1, "/team/presentation#member-" <> &1})
    )
  end

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Team")
     |> assign(:board?, board_here?())
     |> tap(fn s -> if connected?(s) and board_here?(), do: TalesForge.Board.subscribe() end)
     |> assign(:d, TeamPage.data())
     |> assign(:nav, @nav)
     |> assign(:anchors, Jason.encode!(TeamPresentationLive.anchors()))
     |> assign(:aliases, Jason.encode!(aliases()))
     |> assign_stats()}
  end

  defp assign_stats(socket) do
    founder = socket.assigns[:admin_email]

    stats =
      if board_here?() and is_binary(founder),
        do: TeamWorkspace.stats(founder, socket.assigns[:admin_github_login])

    assign(socket, :stats, stats)
  end

  @impl true
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_params(params, _uri, socket),
    do:
      {:noreply,
       socket
       |> assign(:ideas_sort, TalesForgeWeb.TeamIdeaBoard.sort_key(params["sort"]))
       |> assign(:ideas_by, ideas_by(params["by"]))
       |> assign(:ideas_mine, params["mine"] == "1")}

  defp ideas_by(by) when is_binary(by) and by != "", do: String.downcase(by)
  defp ideas_by(_by), do: nil

  # The board lives on production (and locally); playtest keeps the placeholder.
  defp board_here?, do: TalesForge.AppRole.here?(:board)

  @impl true
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:board, :changed}, socket) do
    send_update(TalesForgeWeb.TeamIdeaBoard, id: "idea-board-live", refresh: true)
    {:noreply, assign_stats(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div
      id="team-page"
      class="team-page team-landing paper-themed paper-home min-h-dvh"
      phx-hook="TeamPage"
      data-motion="auto"
    >
      <span
        id="team-anchor-redirect"
        hidden
        phx-hook="TeamAnchorRedirect"
        data-target={~p"/team/presentation"}
        data-anchors={@anchors}
        data-aliases={@aliases}
      />
      <a
        id="skip-to-content"
        href="#team-main"
        class="sr-only focus:not-sr-only focus:fixed focus:left-2 focus:top-2 focus:z-50 focus:rounded focus:bg-[var(--paper-panel)] focus:px-3 focus:py-2 focus:text-[var(--paper-ink)] focus:ring-2"
      >
        Skip to content
      </a>
      <TeamLayout.header socket={assigns[:socket]} page={:landing} items={@nav} />

      <main
        id="team-main"
        tabindex="-1"
        class="mx-auto max-w-6xl space-y-16 px-4 pb-16 pt-8 sm:px-6 sm:pt-12"
      >
        <TeamWorkspace.header stats={assigns[:stats]} />
        <.going_to_do
          board?={assigns[:board?] || false}
          founder={assigns[:admin_email]}
          login={assigns[:admin_github_login]}
          ideas_sort={assigns[:ideas_sort] || "top"}
          ideas_by={assigns[:ideas_by]}
          ideas_mine={assigns[:ideas_mine] || false}
        />
        <.live_section socket={assigns[:socket]} />
        <.presentation />
      </main>

      <TeamLayout.footer d={@d} />
      <Layouts.flash_group flash={@flash} />
    </div>
    """
  end

  # The feed is its own LiveView (TeamPrFeedLive), so its minute-by-minute
  # updates patch only that part and never the page's animation state. Without
  # a socket (render/1 called directly in tests) the current snapshot is shown
  # statically.
  attr :socket, :any, default: nil

  defp live_section(assigns) do
    ~H"""
    <section id="live" class="space-y-5" aria-labelledby="live-title">
      <header class="max-w-3xl space-y-2">
        <h2 id="live-title" class="font-serif text-2xl font-bold sm:text-3xl">
          What we're doing now
        </h2>
        <p class="text-base leading-relaxed text-[var(--paper-muted)] sm:text-lg">
          Live from GitHub, updated every minute: the pull requests in the game's repo, whether their checks
          passed, and whether they're on playtest or in production yet.
        </p>
      </header>
      <%= if @socket do %>
        {live_render(@socket, TalesForgeWeb.TeamPrFeedLive, id: "team-pr-feed")}
      <% else %>
        <TeamPrFeed.feed feed={PrFeed.snapshot()} now={DateTime.utc_now()} />
      <% end %>
    </section>
    """
  end

  defp presentation(assigns) do
    ~H"""
    <section
      id="presentation-cta"
      class="team-callout space-y-4 p-5 sm:p-8"
      aria-labelledby="presentation-cta-title"
    >
      <h2 id="presentation-cta-title" class="font-serif text-2xl font-bold sm:text-3xl">
        The full presentation
      </h2>
      <p class="max-w-3xl leading-relaxed">
        The crew and who does what, how a change gets from an idea to the game, the rules we work by, what the game runs on,
        what the playtests taught us, the pace and cost so far, how the idea board works, and where we go from here, together.
      </p>
      <.link
        id="presentation-link"
        navigate={~p"/team/presentation"}
        class="team-cta inline-flex items-center gap-2 rounded-full px-6 py-3 text-lg font-semibold"
      >
        Open the presentation <.icon name="hero-arrow-right" class="size-5" />
      </.link>
    </section>
    """
  end

  # "What we're going to do": the idea board (`TalesForgeWeb.TeamIdeaBoard`)
  # where it lives (production, local). Playtest redirects /team to
  # production (TalesForgeWeb.Plugs.HomeApp), so there is no placeholder.
  attr :board?, :boolean, default: false
  attr :founder, :string, default: nil
  attr :login, :string, default: nil
  attr :ideas_sort, :string, default: "top"
  attr :ideas_by, :string, default: nil
  attr :ideas_mine, :boolean, default: false

  defp going_to_do(assigns) do
    ~H"""
    <section id="idea-board" class="space-y-5" aria-labelledby="idea-board-title">
      <header class="max-w-3xl space-y-2">
        <h2 id="idea-board-title" class="font-serif text-2xl font-bold sm:text-3xl">
          What we're going to do
        </h2>
        <p class="text-base leading-relaxed text-[var(--paper-muted)] sm:text-lg">
          The founders' idea board: add ideas, vote them up or down, and decide what gets built.
        </p>
      </header>
      <.live_component
        :if={@board? and is_binary(@founder)}
        module={TalesForgeWeb.TeamIdeaBoard}
        id="idea-board-live"
        founder={@founder}
        login={@login}
        ideas_sort={@ideas_sort}
        ideas_by={@ideas_by}
        ideas_mine={@ideas_mine}
      />
    </section>
    """
  end
end
