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

  # The list shows the newest few; the counters still count them all.
  @listed 5

  @doc "The feed: counters and list, or the unavailable notice."
  attr :feed, :map, required: true, doc: "a `t:TalesForge.PrFeed.snapshot/0`"
  attr :fresh, :any, default: MapSet.new(), doc: "PR numbers to animate in"
  attr :now, :any, required: true, doc: "the `DateTime` relative times count from"

  @spec feed(map()) :: Phoenix.LiveView.Rendered.t()
  def feed(%{feed: %{status: :ok}} = assigns) do
    assigns = assign(assigns, :listed, Enum.take(assigns.feed.items, @listed))

    ~H"""
    <div id="pr-feed" class="space-y-4" data-status="ok">
      <%!-- In-flight PRs (open, or merged and not on prod yet) gently pulse:
           only with data-motion="full" (TeamPage hook) and never under
           prefers-reduced-motion. --%>
      <style>
        @keyframes pr-feed-alive { 0%, 100% { box-shadow: inset 3px 0 0 transparent; } 50% { box-shadow: inset 3px 0 0 var(--paper-accent); background: color-mix(in srgb, var(--paper-accent) 6%, transparent); } }
        .team-page[data-motion="full"] .pr-feed-item[data-in-flight] { animation: pr-feed-alive 2.8s ease-in-out infinite; }
        @media (prefers-reduced-motion: reduce) { .pr-feed-item[data-in-flight] { animation: none !important; } }
      </style>
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
          :for={item <- @listed}
          id={"pr-feed-#{item.number}"}
          data-in-flight={in_flight?(item)}
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
            <p :if={stamp(item)} class="text-xs text-[var(--paper-muted)]" data-role="pr-times">
              <span data-role="pr-stamp">{stamp(item)}</span><span :if={span_text(item, @now)}>
                · <span data-role="pr-span">{span_text(item, @now)}</span>
              </span>
            </p>
          </div>
          <div class="flex flex-wrap gap-1.5 sm:max-w-[45%] sm:justify-end">
            <.ci_badge :if={item.state == :open} ci={item.ci} />
            <.deploy_badges :if={item.state == :merged} deployed={item.deployed} />
            <span
              :if={live_on_prod?(item)}
              class="pr-feed-chip"
              data-kind="live-on-prod"
              data-role="live-on-prod"
            >
              ✓ live on prod
            </span>
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
  True for a PR still in flight: open, or merged and waiting for production.
  A PR whose production state is unknown, or that is closed, doesn't count.

      iex> TalesForgeWeb.TeamPrFeed.in_flight?(%{state: :open, deployed: %{production: :not_merged}})
      true
      iex> TalesForgeWeb.TeamPrFeed.in_flight?(%{state: :merged, deployed: %{production: :pending}})
      true
      iex> TalesForgeWeb.TeamPrFeed.in_flight?(%{state: :merged, deployed: %{production: :deployed}})
      false
      iex> TalesForgeWeb.TeamPrFeed.in_flight?(%{state: :closed, deployed: %{production: :not_merged}})
      false
  """
  @spec in_flight?(map()) :: boolean()
  def in_flight?(%{state: :open}), do: true
  def in_flight?(%{state: :merged, deployed: %{production: :pending}}), do: true
  def in_flight?(_item), do: false

  @doc "True for a merged PR that runs on production (shipped: no pulse, a done marker)."
  @spec live_on_prod?(map()) :: boolean()
  def live_on_prod?(%{state: :merged, deployed: %{production: :deployed}}), do: true
  def live_on_prod?(_item), do: false

  @doc """
  When the PR was merged (merged ones) or opened (the rest), on Stockholm time
  with CET/CEST, labelled; nil without a time.

      iex> TalesForgeWeb.TeamPrFeed.stamp(%{state: :merged, merged_at: ~U[2026-10-10 03:41:00Z], opened_at: ~U[2026-10-10 03:20:00Z]})
      "Merged 10 Oct 05:41 CEST"
      iex> TalesForgeWeb.TeamPrFeed.stamp(%{state: :open, merged_at: nil, opened_at: ~U[2026-12-01 09:05:00Z]})
      "Opened 1 Dec 10:05 CET"
  """
  @spec stamp(map()) :: String.t() | nil
  def stamp(%{state: :merged, merged_at: %DateTime{} = at}), do: "Merged " <> local(at)
  def stamp(%{opened_at: %DateTime{} = at}), do: "Opened " <> local(at)
  def stamp(_item), do: nil

  defp local(at), do: at |> TimeAgo.stockholm("%-d %b %H:%M %Z")

  @doc """
  How long: "open for X" while open, "took X from open to merge" once merged.
  Real elapsed time, so a DST change doesn't add or lose an hour.

      iex> TalesForgeWeb.TeamPrFeed.span_text(%{state: :open, opened_at: ~U[2026-10-10 01:00:00Z], merged_at: nil}, ~U[2026-10-10 03:05:00Z])
      "open for 2 h 5 min"
      iex> TalesForgeWeb.TeamPrFeed.span_text(%{state: :merged, opened_at: ~U[2026-10-08 08:00:00Z], merged_at: ~U[2026-10-09 09:30:00Z]}, ~U[2026-10-10 00:00:00Z])
      "took 1 d 1 h from open to merge"
  """
  @spec span_text(map(), DateTime.t()) :: String.t() | nil
  def span_text(%{state: :merged, opened_at: %DateTime{} = o, merged_at: %DateTime{} = m}, _now),
    do: "took #{duration(DateTime.diff(m, o))} from open to merge"

  def span_text(%{state: :open, opened_at: %DateTime{} = o}, now),
    do: "open for #{duration(DateTime.diff(now, o))}"

  def span_text(_item, _now), do: nil

  @doc """
  A duration in seconds, in words.

      iex> Enum.map([30, 59 * 60, 3600, 90_000, 3 * 86_400], &TalesForgeWeb.TeamPrFeed.duration/1)
      ["under a minute", "59 min", "1 h", "1 d 1 h", "3 d"]
  """
  @spec duration(integer()) :: String.t()
  def duration(s) when s < 60, do: "under a minute"
  def duration(s) when s < 3600, do: "#{div(s, 60)} min"

  def duration(s) when s < 86_400 do
    m = div(rem(s, 3600), 60)
    "#{div(s, 3600)} h" <> if(m > 0, do: " #{m} min", else: "")
  end

  def duration(s) do
    h = div(rem(s, 86_400), 3600)
    "#{div(s, 86_400)} d" <> if(h > 0, do: " #{h} h", else: "")
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
