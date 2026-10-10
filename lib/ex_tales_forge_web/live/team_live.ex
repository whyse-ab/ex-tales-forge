defmodule TalesForgeWeb.TeamLive do
  @moduledoc """
  The founders' landing page at `/team`, top to bottom:

  1. the hero with the painted crew (`hero/1`);
  2. **What we're going to do** (`#idea-board`): the founders' idea board
     (`TalesForgeWeb.TeamIdeaBoard`, live over `TalesForge.Board`'s PubSub) on
     production and locally; on playtest the "coming soon" placeholder
     (`#board-soon`, `data-slot="shared-board"`) in the same slot;
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

  import TalesForge.TeamPage, only: [count_word: 1]

  alias TalesForge.PrFeed
  alias TalesForge.TeamPage
  alias TalesForgeWeb.Layouts
  alias TalesForgeWeb.TeamArt
  alias TalesForgeWeb.TeamBoard
  alias TalesForgeWeb.TeamLayout
  alias TalesForgeWeb.TeamPresentationLive
  alias TalesForgeWeb.TeamPrFeed

  @nav [
    {"idea-board", "Going to do"},
    {"live", "Doing now"},
    {"presentation-cta", "Presentation"}
  ]

  @doc """
  This page's own anchors (its nav and sections). None of them is a
  presentation anchor, so the redirect hook leaves them alone.

      iex> TalesForgeWeb.TeamLive.anchors()
      ["idea-board", "live", "presentation-cta", "landing-hero"]
  """
  @spec anchors() :: [String.t()]
  def anchors, do: Enum.map(@nav, &elem(&1, 0)) ++ ~w(landing-hero)

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
     |> assign(:aliases, Jason.encode!(aliases()))}
  end

  # The board lives on production (and locally); playtest keeps the placeholder.
  defp board_here?, do: TalesForge.AppRole.here?(:board)

  @impl true
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:board, :changed}, socket) do
    send_update(TalesForgeWeb.TeamIdeaBoard, id: "idea-board-live", refresh: true)
    {:noreply, socket}
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
      <TeamLayout.header page={:landing} items={@nav} />

      <main class="mx-auto max-w-6xl space-y-16 px-4 pb-16 pt-8 sm:px-6 sm:pt-12">
        <.hero d={@d} />
        <.going_to_do board?={assigns[:board?] || false} founder={assigns[:admin_email]} />
        <.live_section socket={assigns[:socket]} />
        <.presentation />
      </main>

      <TeamLayout.footer d={@d} />
      <Layouts.flash_group flash={@flash} />
    </div>
    """
  end

  attr :d, :map, required: true

  defp hero(assigns) do
    assigns = assign(assigns, :holder, TeamPage.approval_holder(assigns.d))

    ~H"""
    <section
      id="landing-hero"
      class="grid items-center gap-8 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]"
      aria-labelledby="landing-title"
    >
      <div class="space-y-5">
        <h1 id="landing-title" class="font-serif text-4xl font-bold leading-tight sm:text-5xl">
          How Tales Forge gets built
        </h1>
        <p class="text-lg leading-relaxed text-[var(--paper-muted)]">
          The founders and {count_word(TeamPage.bot_count(@d))} bots, one crew, taking a lot of small, careful steps.
        </p>
        <aside id="landing-starting-point" class="team-callout flex gap-3 p-4">
          <TeamArt.seal class="size-10 shrink-0" />
          <p class="text-sm leading-relaxed sm:text-base">
            <strong>This is how we work today, and it's a starting point.</strong>
            Right now {@holder} holds the approval key for merges and deploys. That's where we began, not where we stop.
            Soon every founder will be able to do the same: approve changes, steer the bots and make decisions.
          </p>
        </aside>
      </div>
      <div class="team-card overflow-hidden p-3">
        <TeamArt.picture
          id="landing-hero-art"
          name="hero"
          sizes="(min-width: 1152px) 528px, (min-width: 1024px) calc(50vw - 3rem), calc(100vw - 3.5rem)"
          loading="eager"
          fetchpriority="high"
          class="block aspect-video h-auto w-full rounded-lg object-cover"
        />
      </div>
    </section>
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
        what the playtests taught us, the pace and cost so far, the shared board that's coming, and where we go from here, together.
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
  # where it lives (production, local); elsewhere the "coming soon"
  # placeholder (#board-soon).
  attr :board?, :boolean, default: false
  attr :founder, :string, default: nil

  defp going_to_do(assigns) do
    assigns = assign(assigns, :board, TeamBoard.anchor())

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
      />
      <div
        :if={not (@board? and is_binary(@founder))}
        id="board-soon"
        class="team-board-soon space-y-3 rounded-xl border-2 border-dashed border-[var(--paper-rule)] p-5 text-center sm:p-8"
        data-slot="shared-board"
      >
        <p class="team-badge team-soon mx-auto">
          <.icon name="hero-sparkles-micro" class="size-4" /> Coming soon. Not built yet.
        </p>
        <h3 class="font-serif text-xl font-bold">One shared board</h3>
        <p class="mx-auto max-w-2xl text-sm leading-relaxed text-[var(--paper-muted)] sm:text-base">
          One board, the whole crew, from idea to done. This is where it will live.
        </p>
        <.link
          navigate={"/team/presentation##{@board}"}
          class="inline-block text-sm font-semibold text-[var(--paper-accent)] underline"
        >
          How it will work →
        </.link>
      </div>
    </section>
    """
  end
end
