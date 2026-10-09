defmodule TalesForgeWeb.TeamLive do
  @moduledoc """
  The founders' landing page at `/team`: the hero with the painted crew, a
  short card for each of the crew (the founders and the three bots, with their
  portraits), a prominent way into the full presentation at
  `/team/presentation` (`TalesForgeWeb.TeamPresentationLive`) and a marked,
  "coming soon" spot where the shared board will live.

  The page is a stack of independent sections (`hero/1`, `crew/1`,
  `presentation/1`, `board_soon/1`), each an `id`'d `<section>` with its own
  assigns, so more can slot in between them later without touching the
  others. The live PR feed (ex-tales-forge #102, on hold) is meant to go in
  after the crew, where the template marks it.

  Old links to the presentation's sections (`/team#playtests`) still work: the
  server never sees the `#`, so the `TeamAnchorRedirect` hook
  (`assets/js/team_hooks.js`) replaces the URL with
  `/team/presentation#playtests` when the anchor is one of
  `TalesForgeWeb.TeamPresentationLive.anchors/0`, passed in `data-anchors`.
  This page's own anchors are named so they never collide with those.

  Behind the GitHub team sign-in like every page (router `:browser` pipeline
  plus the `:require_team_member` mount hook, the same `:play` live session as
  the presentation). Read-only: no events, no AI calls, no database. Copy
  follows tales-forge-docs `docs/team-page/content.md`; numbers come from
  `TalesForge.TeamPage`.
  """

  use TalesForgeWeb, :live_view

  import TalesForge.TeamPage, only: [get: 2, count_word: 1]

  alias TalesForge.TeamPage
  alias TalesForgeWeb.Layouts
  alias TalesForgeWeb.TeamArt
  alias TalesForgeWeb.TeamBoard
  alias TalesForgeWeb.TeamLayout
  alias TalesForgeWeb.TeamPresentationLive

  @nav [{"crew", "The crew"}, {"board-soon", "Shared board"}]

  # One line per crew member, the first line of their card in the brief.
  @short %{
    "founders" => "Shape what we build: ideas, surveys and playing the game.",
    "case" => "The crew's go-to bot. Turns ideas into plans and hands the work to Bobby.",
    "bobby" => "Writes all the code, always as pull requests.",
    "gentry" =>
      "Plays the game like a troublemaker: prompt injections, fake GM notes and false claims."
  }

  @badges %{
    "case" => "Hourly status · daily cleanup",
    "bobby" => "Hourly log check",
    "gentry" => "Weekdays 07:13 · after every playtest deploy"
  }

  @doc """
  This page's own anchors (its nav and sections). None of them is a
  presentation anchor, so the redirect hook leaves them alone.

      iex> TalesForgeWeb.TeamLive.anchors()
      ["crew", "board-soon", "landing-hero", "presentation-cta"]
  """
  @spec anchors() :: [String.t()]
  def anchors, do: Enum.map(@nav, &elem(&1, 0)) ++ ~w(landing-hero presentation-cta)

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Team")
     |> assign(:d, TeamPage.data())
     |> assign(:nav, @nav)
     |> assign(:anchors, Jason.encode!(TeamPresentationLive.anchors()))}
  end

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
      />
      <TeamLayout.header page={:landing} items={@nav} />

      <main class="mx-auto max-w-6xl space-y-16 px-4 pb-16 pt-8 sm:px-6 sm:pt-12">
        <.hero d={@d} />
        <.crew d={@d} />
        <%!-- The live PR feed (#102, on hold) slots in here, as its own <section>. --%>
        <.presentation />
        <.board_soon />
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
        <.link
          id="hero-presentation-link"
          navigate={~p"/team/presentation"}
          class="team-cta inline-flex items-center gap-2 rounded-full px-5 py-2.5 text-base font-semibold"
        >
          See the full presentation <.icon name="hero-arrow-right" class="size-5" />
        </.link>
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

  attr :d, :map, required: true

  defp crew(assigns) do
    assigns = assign(assigns, :members, TeamPage.members(assigns.d))

    ~H"""
    <section id="crew" class="space-y-5" aria-labelledby="crew-title">
      <header class="max-w-3xl space-y-2">
        <h2 id="crew-title" class="font-serif text-2xl font-bold sm:text-3xl">The crew</h2>
        <p class="text-base leading-relaxed text-[var(--paper-muted)] sm:text-lg">
          Tales Forge is built by one crew: the founders and {count_word(TeamPage.bot_count(@d))} bots.
          The bots do a lot of the hands-on work, and nothing reaches the game without a founder's yes.
        </p>
      </header>
      <ul id="crew-cards" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <li
          :for={member <- @members}
          id={"crew-#{member["id"]}"}
          class="team-card flex flex-col gap-3 p-4"
        >
          <TeamArt.picture
            :if={TeamArt.portrait?(member["id"])}
            id={"crew-portrait-#{member["id"]}"}
            name={member["id"]}
            sizes="(min-width: 1152px) 240px, (min-width: 1024px) calc(25vw - 3rem), (min-width: 640px) calc(50vw - 4rem), calc(100vw - 4rem)"
            class="team-portrait block aspect-[4/3] h-auto w-full rounded-lg object-cover"
          />
          <div class="flex items-center gap-3">
            <TeamArt.avatar
              :if={!TeamArt.portrait?(member["id"])}
              id={member["id"]}
              class="size-16"
              label={member["name"]}
            />
            <div class="min-w-0">
              <h3 class="font-serif text-lg font-bold leading-tight">{member["name"]}</h3>
              <p class="text-xs text-[var(--paper-muted)]">{member["role"]}</p>
            </div>
          </div>
          <p class="flex-1 text-sm leading-snug">{short(member)}</p>
          <p :if={badge(member, @d)} class="team-badge">{badge(member, @d)}</p>
          <.link
            navigate={"/team/presentation#member-#{member["id"]}"}
            class="text-sm font-semibold text-[var(--paper-accent)] underline"
          >
            More about {more_name(member["name"])} →
          </.link>
        </li>
      </ul>
    </section>
    """
  end

  defp presentation(assigns) do
    assigns = assign(assigns, :sections, TeamPresentationLive.sections())

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
        Who does what, how a change gets from an idea to the game, the rules we work by, what the game runs on,
        what the playtests taught us, the pace and cost so far, the shared board that's coming, and where we go from here, together.
      </p>
      <.link
        id="presentation-link"
        navigate={~p"/team/presentation"}
        class="team-cta inline-flex items-center gap-2 rounded-full px-6 py-3 text-lg font-semibold"
      >
        Open the presentation <.icon name="hero-arrow-right" class="size-5" />
      </.link>
      <ol id="presentation-contents" class="flex flex-wrap gap-x-4 gap-y-1 text-sm">
        <li :for={{{id, label}, i} <- Enum.with_index(@sections, 1)}>
          <.link navigate={"/team/presentation##{id}"} class="underline underline-offset-2">
            {i}. {label}
          </.link>
        </li>
      </ol>
    </section>
    """
  end

  defp board_soon(assigns) do
    assigns = assign(assigns, :board, TeamBoard.anchor())

    ~H"""
    <section
      id="board-soon"
      class="team-board-soon space-y-3 rounded-xl border-2 border-dashed border-[var(--paper-rule)] p-5 text-center sm:p-8"
      aria-labelledby="board-soon-title"
      data-slot="shared-board"
    >
      <p class="team-badge team-soon mx-auto">
        <.icon name="hero-sparkles-micro" class="size-4" /> Coming soon. Not built yet.
      </p>
      <h2 id="board-soon-title" class="font-serif text-2xl font-bold">One shared board</h2>
      <p class="mx-auto max-w-2xl text-sm leading-relaxed text-[var(--paper-muted)] sm:text-base">
        Coming soon: one board, the whole crew, from idea to done. This is where it will live.
      </p>
      <.link
        navigate={"/team/presentation##{@board}"}
        class="inline-block text-sm font-semibold text-[var(--paper-accent)] underline"
      >
        How it will work →
      </.link>
    </section>
    """
  end

  defp more_name("The " <> rest), do: "the " <> rest
  defp more_name(name), do: name

  defp short(member), do: Map.get(@short, member["id"]) || List.first(member["does"] || []) || ""

  defp badge(%{"id" => "founders"} = member, d) do
    case get(member, ["approval_key", "later"]) do
      later when is_binary(later) ->
        "The approval key: #{TeamPage.approval_holder(d)} today, #{later} soon"

      _missing ->
        nil
    end
  end

  defp badge(%{"id" => id}, _d), do: Map.get(@badges, id)
  defp badge(_member, _d), do: nil
end
