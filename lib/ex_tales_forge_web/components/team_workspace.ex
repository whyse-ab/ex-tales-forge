defmodule TalesForgeWeb.TeamWorkspace do
  @moduledoc """
  The compact shared-workspace header on top of `/team` (`#workspace`): the
  title, one subtitle and four quick stats. Each stat is a link to the place on
  the idea board where you act on it:

    * **Ideas waiting for votes**: the cards in the Ideas column
      (`#board-col-ideas`).
    * **Founder check cards for you**: the cards in Founder check that the
      signed-in founder has not voted on yet, or that have an open question
      with no answer (not answered and not deferred, see
      `TalesForge.Board.Answer.settled?/1`). Links to `#board-col-check`.
    * **PRs waiting for approval**: the Building cards whose PR waits for an
      Approve (`TalesForge.Board.pr_waiting?/1`). Links to
      `#board-col-building`.
    * **Pings for you**: the signed-in founder's unread pings, the same number
      the board shows (`TalesForge.Board.unread_pings/1`). Links to
      `#board-pings`.

  Every founder can approve, so the copy names no one role. Copy follows
  tales-forge-docs `docs/team-page/content.md`.
  """

  use Phoenix.Component

  alias TalesForge.Board
  alias TalesForge.Board.Answer

  @typedoc "The four numbers of the header."
  @type stats :: %{
          ideas: non_neg_integer(),
          check: non_neg_integer(),
          prs: non_neg_integer(),
          pings: non_neg_integer()
        }

  @doc """
  The four numbers for `founder` (email) and `login` (GitHub login), from the
  board as it is now.
  """
  @spec stats(String.t(), String.t() | nil) :: stats()
  def stats(founder, login) do
    board = Board.board()

    %{
      ideas: length(board["ideas"] || []),
      check: Enum.count(board["check"] || [], &needs_you?(&1, founder)),
      prs: Enum.count(board["building"] || [], &Board.pr_waiting?/1),
      pings: login |> Board.unread_pings() |> Enum.map(& &1.count) |> Enum.sum()
    }
  end

  @doc """
  True when a Founder check card needs `founder`: no vote from them yet, or an
  open question with no answer.
  """
  @spec needs_you?(Board.Idea.t(), String.t()) :: boolean()
  def needs_you?(idea, founder) do
    Board.vote_of(idea, founder) == nil or
      Enum.any?(Board.questions(idea), fn {_q, a} -> not Answer.settled?(a) end)
  end

  attr :stats, :map, default: nil

  @doc "The header. Without `stats` (no board here) it shows the title only."
  @spec header(map()) :: Phoenix.LiveView.Rendered.t()
  def header(assigns) do
    ~H"""
    <section id="workspace" class="space-y-4" aria-labelledby="workspace-title">
      <header class="space-y-1">
        <h1 id="workspace-title" class="font-serif text-3xl font-bold leading-tight sm:text-4xl">
          Our workspace
        </h1>
        <p id="workspace-subtitle" class="text-base text-[var(--paper-muted)] sm:text-lg">
          Ideas, building and chat for the whole crew
        </p>
      </header>
      <nav :if={@stats} id="workspace-stats" aria-label="Quick stats">
        <ul class="grid grid-cols-2 gap-3 sm:grid-cols-4">
          <.stat
            id="stat-ideas"
            href="#board-col-ideas"
            n={@stats.ideas}
            label="Ideas waiting for votes"
          />
          <.stat
            id="stat-check"
            href="#board-col-check"
            n={@stats.check}
            label="Founder check cards for you"
            hint="Vote or answer a question"
          />
          <.stat
            id="stat-prs"
            href="#board-col-building"
            n={@stats.prs}
            label="PRs waiting for approval"
          />
          <.stat id="stat-pings" href="#board-pings" n={@stats.pings} label="Pings for you" />
        </ul>
      </nav>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :href, :string, required: true
  attr :n, :integer, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil

  defp stat(assigns) do
    ~H"""
    <li>
      <a
        id={@id}
        href={@href}
        class="team-card flex min-h-[44px] h-full flex-col gap-1 p-3 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2"
      >
        <span class="font-serif text-2xl font-bold" data-count>{@n}</span>
        <span class="text-sm leading-snug">{@label}</span>
        <span :if={@hint} class="text-xs text-[var(--paper-muted)]">{@hint}</span>
      </a>
    </li>
    """
  end
end
