defmodule TalesForgeWeb.TeamPrFeed do
  @moduledoc """
  The live PR feed of the founders' page (`/team`, section "Live: what we're
  shipping"), rendered by `TalesForgeWeb.TeamPrFeedLive` from a
  `t:TalesForge.PrFeed.snapshot/0`: the merged-today and this-week counters
  and the latest pull requests with state, author, relative time, CI (open
  ones) and where merged ones are deployed.

  When the feed has no data (`:not_configured`, `:unavailable`) it says "Live
  feed unavailable" and why; the rest of the page doesn't depend on it. Rows
  whose number or state is new since the last update carry `data-fresh` and
  slide in (app.css, only with `data-motion="full"`, never with reduced motion).
  """

  use Phoenix.Component

  alias TalesForge.PrFeed
  alias TalesForgeWeb.TimeAgo

  @doc "The feed: counters and list, or the unavailable notice."
  attr :feed, :map, required: true, doc: "a `t:TalesForge.PrFeed.snapshot/0`"
  attr :fresh, :any, default: MapSet.new(), doc: "PR numbers to animate in"
  attr :now, :any, required: true, doc: "the `DateTime` relative times count from"

  @spec feed(map()) :: Phoenix.LiveView.Rendered.t()
  def feed(%{feed: %{status: :ok}} = assigns) do
    ~H"""
    <div id="pr-feed" class="space-y-4" data-status="ok">
      <div class="flex flex-wrap items-stretch gap-3">
        <div
          id="pr-feed-today"
          class="team-card flex min-w-[8.5rem] flex-1 flex-col gap-1 p-3 sm:flex-none"
        >
          <span class="font-serif text-3xl font-bold leading-none text-[var(--paper-accent)]">
            {@feed.merged_today}
          </span>
          <span class="text-sm font-semibold">merged today</span>
        </div>
        <div
          id="pr-feed-week"
          class="team-card flex min-w-[8.5rem] flex-1 flex-col gap-1 p-3 sm:flex-none"
        >
          <span class="font-serif text-3xl font-bold leading-none text-[var(--paper-accent)]">
            {@feed.merged_week}
          </span>
          <span class="text-sm font-semibold">merged this week</span>
        </div>
        <p class="flex w-full items-center gap-2 self-end text-xs text-[var(--paper-muted)] sm:ml-auto sm:w-auto">
          <span class="pr-feed-dot" aria-hidden="true"></span>
          <span>
            Live from GitHub<span :if={@feed.fetched_at}>, checked {TimeAgo.relative(
              @feed.fetched_at,
              @now
            )}</span>
          </span>
        </p>
      </div>

      <p :if={@feed.items == []} id="pr-feed-empty" class="text-sm text-[var(--paper-muted)]">
        No pull requests yet.
      </p>

      <ol
        :if={@feed.items != []}
        id="pr-feed-list"
        class="team-card divide-y divide-[var(--paper-rule)] overflow-hidden"
        aria-label="Latest pull requests"
      >
        <li
          :for={item <- @feed.items}
          id={"pr-feed-#{item.number}"}
          class="pr-feed-item flex flex-col gap-2 px-3 py-3 sm:flex-row sm:items-start sm:gap-4 sm:px-4"
          data-state={item.state}
          data-fresh={MapSet.member?(@fresh, item.number)}
        >
          <.state_pill item={item} />
          <div class="min-w-0 flex-1 space-y-1">
            <p class="break-words font-semibold leading-snug">
              <a :if={item.url} href={item.url} target="_blank" rel="noopener" class="hover:underline">
                {item.title}
              </a>
              <span :if={!item.url}>{item.title}</span>
            </p>
            <p class="text-xs text-[var(--paper-muted)]">
              #{item.number}<span :if={item.author}> · {item.author}</span><span :if={item.at}>
                ·
                <time datetime={DateTime.to_iso8601(item.at)} title={TimeAgo.stockholm(item.at)}>{verb(
                  item.state
                )} {TimeAgo.relative(item.at, @now)}</time>
              </span>
            </p>
          </div>
          <div class="flex flex-wrap gap-1.5 sm:max-w-[45%] sm:justify-end">
            <.ci_badge :if={item.state == :open} ci={item.ci} />
            <.deploy_badges :if={item.state == :merged} deployed={item.deployed} />
          </div>
        </li>
      </ol>
    </div>
    """
  end

  def feed(%{feed: %{status: :loading}} = assigns) do
    ~H"""
    <div id="pr-feed" class="team-callout p-4 text-sm text-[var(--paper-muted)]" data-status="loading">
      Loading the live feed…
    </div>
    """
  end

  def feed(assigns) do
    ~H"""
    <div id="pr-feed" class="team-callout space-y-1 p-4" data-status={@feed.status}>
      <p id="pr-feed-unavailable" class="font-semibold">Live feed unavailable</p>
      <p class="text-sm text-[var(--paper-muted)]">{reason(@feed.status)}</p>
    </div>
    """
  end

  @doc """
  Why there's no feed, in words.

      iex> TalesForgeWeb.TeamPrFeed.reason(:unavailable)
      "GitHub didn't answer just now. We try again every minute."
  """
  @spec reason(PrFeed.status()) :: String.t()
  def reason(:not_configured), do: "This app has no GitHub token for the feed yet."
  def reason(:unavailable), do: "GitHub didn't answer just now. We try again every minute."
  def reason(_status), do: "No data yet."

  attr :item, :map, required: true

  defp state_pill(assigns) do
    ~H"""
    <span class="pr-feed-pill shrink-0 self-start" data-kind={pill_kind(@item)}>
      {pill_label(@item)}
    </span>
    """
  end

  defp pill_kind(%{state: :open, draft: true}), do: "draft"
  defp pill_kind(%{state: state}), do: Atom.to_string(state)

  defp pill_label(%{state: :open, draft: true}), do: "Draft"
  defp pill_label(%{state: :open}), do: "Open"
  defp pill_label(%{state: :merged}), do: "Merged"
  defp pill_label(%{state: :closed}), do: "Closed"

  attr :ci, :atom, default: nil

  defp ci_badge(assigns) do
    ~H"""
    <span class="pr-feed-chip" data-kind={"ci-#{@ci || :none}"}>{ci_label(@ci)}</span>
    """
  end

  @doc """
  The CI badge text of an open pull request.

      iex> TalesForgeWeb.TeamPrFeed.ci_label(:passed)
      "CI passing"
      iex> TalesForgeWeb.TeamPrFeed.ci_label(nil)
      "CI not run yet"
  """
  @spec ci_label(PrFeed.ci()) :: String.t()
  def ci_label(:passed), do: "CI passing"
  def ci_label(:failed), do: "CI failing"
  def ci_label(:running), do: "CI running"
  def ci_label(:cancelled), do: "CI cancelled"
  def ci_label(nil), do: "CI not run yet"

  attr :deployed, :map, required: true

  defp deploy_badges(assigns) do
    assigns = assign(assigns, :badges, deploy_labels(assigns.deployed))

    ~H"""
    <span :for={{kind, label} <- @badges} class="pr-feed-chip" data-kind={kind}>{label}</span>
    """
  end

  @doc """
  The deployment badges of a merged pull request: one per app it runs on,
  else the first app it is still waiting for. Unknown apps get no badge.

      iex> TalesForgeWeb.TeamPrFeed.deploy_labels(%{playtest: :deployed, production: :deployed})
      [{"on-playtest", "on playtest"}, {"on-prod", "on prod"}]
      iex> TalesForgeWeb.TeamPrFeed.deploy_labels(%{playtest: :deployed, production: :pending})
      [{"on-playtest", "on playtest"}, {"waiting", "not on prod yet"}]
      iex> TalesForgeWeb.TeamPrFeed.deploy_labels(%{playtest: :pending, production: :pending})
      [{"waiting", "not on playtest yet"}]
      iex> TalesForgeWeb.TeamPrFeed.deploy_labels(%{playtest: :unknown, production: :unknown})
      []
  """
  @spec deploy_labels(%{playtest: atom(), production: atom()}) :: [{String.t(), String.t()}]
  def deploy_labels(deployed) do
    on =
      for {app, kind, label} <- [
            {:playtest, "on-playtest", "on playtest"},
            {:production, "on-prod", "on prod"}
          ],
          deployed[app] == :deployed,
          do: {kind, label}

    waiting =
      cond do
        deployed[:playtest] == :pending -> [{"waiting", "not on playtest yet"}]
        deployed[:production] == :pending -> [{"waiting", "not on prod yet"}]
        true -> []
      end

    on ++ waiting
  end

  defp verb(:merged), do: "merged"
  defp verb(:closed), do: "closed"
  defp verb(:open), do: "opened"
end
