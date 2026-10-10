defmodule TalesForgeWeb.AdminLive.CostsLive do
  @moduledoc """
  Admin costs page (`/admin/operate/costs`), read-only, USD with SEK alongside at the
  configured rate. The Jev intent latency of this app's last 7 days is at the
  bottom (`TalesForgeWeb.TeamLiveNumbers.intent_latency/2`). Scope: AI calls only (xAI/Grok, TypeSafe Jev). What it shows
  depends on the app's role (`TalesForge.AppRole`):

  - **Playtest:** only playtest-run spend (`TalesForge.Costs.PlaytestRuns`):
    GM, Jev intent and other game calls, then the persona bot and Jev scoring
    apart from game cost. Other calls on playtest (manual play) are one
    separate line, not in the runs' total.
  - **Production (and local):** all AI spend. One grand total on top
    (production + playtest runs + playtest's other calls), production's own
    buckets and call metrics, and a Playtest section read live from playtest
    (`TalesForge.Costs.Peer`, 2 s timeout, after the page has rendered). If
    playtest is down the section says "playtest unavailable" and the grand total
    is production's alone; without `COSTS_PEER_TOKEN` it says "not configured".
    Fixed monthly costs are listed below, outside the grand total.
  """

  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents,
    only: [section_card: 1, call_breakdown: 1, format_latency: 1, format_pct: 1, format_usd: 1]

  alias TalesForge.AICalls
  alias TalesForge.AICalls.Metrics
  alias TalesForge.AppRole
  alias TalesForge.Costs
  alias TalesForge.Costs.Peer
  alias TalesForge.Costs.PlaytestRuns
  alias TalesForge.TeamPage
  alias TalesForgeWeb.TeamLiveNumbers

  @line_labels %{
    "gm" => "GM",
    "jev_intent" => "Jev intent",
    "other_game" => "Other game calls",
    "persona" => "Persona bot",
    "jev_scoring" => "Jev scoring"
  }

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Costs")
      |> assign(:rate, Costs.usd_sek())

    now = DateTime.utc_now()

    {:ok,
     socket
     |> assign(:latency, TeamLiveNumbers.intent_latency(TeamPage.data(), now))
     |> mount_role(AppRole.role(), now)}
  end

  defp mount_role(socket, :playtest, now) do
    socket
    |> assign(:role, :playtest)
    |> assign(:runs, PlaytestRuns.summary(now))
  end

  defp mount_role(socket, role, now) do
    local = Costs.ai_summary(now)
    configured? = Peer.configured?()
    playtest = if configured?, do: :loading, else: {:error, :not_configured}

    socket =
      if configured? and connected?(socket),
        do: start_async(socket, :playtest, fn -> Peer.fetch() end),
        else: socket

    socket
    |> assign(:role, role)
    |> assign(:local, local)
    |> assign(:metrics, Metrics.period(AICalls.month_start(now), now))
    |> assign_playtest(playtest)
  end

  @impl true
  @spec handle_async(atom(), {:ok, term()} | {:exit, term()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_async(:playtest, {:ok, result}, socket),
    do: {:noreply, assign_playtest(socket, result)}

  def handle_async(:playtest, {:exit, _reason}, socket),
    do: {:noreply, assign_playtest(socket, {:error, :unreachable})}

  defp assign_playtest(socket, playtest) do
    report_playtest = if playtest == :loading, do: {:error, :loading}, else: playtest

    socket
    |> assign(:playtest, playtest)
    |> assign(:report, Costs.report(socket.assigns.local, report_playtest))
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(%{role: :playtest} = assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active="costs" other_app_path="/admin/operate/costs">
      <.page_header rate={@rate}>
        This is the playtest app: only the AI spend of playtest runs (persona bot sessions) is
        counted here. Production's page shows all costs, this app's included. Manual play on
        playtest shows there as "Playtest: other calls".
      </.page_header>
      <p>
        <a
          id="costs-total-on-production"
          href={AppRole.base_url(:production) <> "/admin/operate/costs"}
          data-cross-app
          class="inline-flex min-h-11 items-center font-semibold text-[var(--paper-accent)] underline"
        >
          Total and all costs on production ↗
        </a>
      </p>

      <.runs_section
        id="costs-runs"
        title={"Playtest runs (#{@runs["app"]})"}
        summary={@runs}
        rate={@rate}
      />

      <.latency_card latency={@latency} />
    </Layouts.admin>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active="costs" other_app_path="/admin/operate/costs">
      <.page_header rate={@rate}>
        All AI spend: this app's own calls and, read live from the playtest app, its playtest
        runs and other calls. Nothing is copied between the apps.
      </.page_header>

      <.section_card title="All costs · this month" id="costs-total">
        <dl class="divide-y divide-[var(--paper-rule)] text-sm">
          <.money_row
            id="costs-total-production"
            label={"#{Costs.env_label(@local["app"])}: AI"}
            micro={@report.production_month_micro_usd}
            rate={@rate}
          />
          <%= if @report.playtest_included do %>
            <.money_row
              id="costs-total-playtest-runs"
              label={"Playtest runs: AI (game #{usd(@report.playtest_game_month_micro_usd)}, bots #{usd(@report.playtest_bots_month_micro_usd)})"}
              micro={@report.playtest_runs_month_micro_usd}
              rate={@rate}
            />
            <.money_row
              id="costs-total-playtest-outside"
              label="Playtest, outside runs (manual play etc.): AI"
              micro={@report.playtest_outside_month_micro_usd}
              rate={@rate}
            />
          <% else %>
            <div id="costs-total-playtest-missing" class="flex justify-between gap-x-4 py-2">
              <dt class="text-[var(--paper-ink)]">Playtest: AI</dt>
              <dd class="text-[var(--paper-muted)]">{playtest_short(@playtest)}</dd>
            </div>
          <% end %>
          <.money_row
            id="costs-grand-total"
            label={"Grand total so far (#{scope(@report)})"}
            micro={@report.grand_month_micro_usd}
            rate={@rate}
            strong
          />
          <.money_row
            id="costs-grand-projected"
            label="Projected to month end"
            micro={@report.grand_projected_micro_usd}
            rate={@rate}
          />
        </dl>
        <p class="text-xs text-[var(--paper-muted)]">
          AI calls only (xAI and TypeSafe Jev); fixed hosting costs are listed below and not in this total.
          Projection: each app's spend this month / days elapsed * days in the month.
        </p>
        <p
          :if={!@report.playtest_included}
          id="costs-peer-excluded"
          class="text-sm text-[var(--paper-muted)]"
        >
          Playtest AI spend is not included ({playtest_short(@playtest)}).
        </p>
        <.playtest_line check={@report.playtest} rate={@rate} />
        <a
          id="costs-playtest-details"
          href={AppRole.base_url(:playtest) <> "/admin/operate/costs"}
          data-cross-app
          class="inline-flex min-h-11 items-center text-sm font-semibold text-[var(--paper-accent)] underline"
        >
          Playtest run details on playtest ↗
        </a>
      </.section_card>

      <.env_section
        id="costs-env-local"
        summary={@local}
        rate={@rate}
        title={Costs.env_label(@local["app"])}
      />

      <.section_card title="Calls by type · this month (this app)" id="costs-call-types">
        <dl id="costs-cache" class="grid gap-x-6 gap-y-1 text-sm sm:grid-cols-2">
          <.metric_row
            id="costs-cache-gm-later"
            label="GM cache, turns 2+"
            value={cache_line(@metrics.cache.gm_later)}
          />
          <.metric_row
            id="costs-cache-gm"
            label="GM cache, all turns"
            value={cache_line(@metrics.cache.gm)}
          />
          <.metric_row
            id="costs-cache-game"
            label="All game LLM calls"
            value={cache_line(@metrics.cache.game)}
          />
          <.metric_row
            id="costs-idle-gap"
            label="GM idle gap p50 / p90"
            value={"#{format_latency(@metrics.idle_gap.p50_ms)} / #{format_latency(@metrics.idle_gap.p90_ms)}"}
          />
        </dl>
        <.call_breakdown id="costs-breakdown" rows={@metrics.breakdown} per_session />
        <p class="text-xs text-[var(--paper-muted)]">
          Call types as in docs/call-types.md: <code>llm</code>
          (xAI), <code>jev</code>
          (TypeSafe) and <code>function</code>
          (timed Elixir turn steps, free, not counted as calls).
          Persona and scorer are the playtest bots and are never added to game cost.
          /session and /turn divide by the {@metrics.counts["game"].sessions} game sessions and {@metrics.counts[
            "game"
          ].turns} GM turns this month (persona rows by persona sessions and turns).
          Cache: cached / input tokens, and calls with more than {Metrics.cache_floor()} cached tokens
          (xAI reports {Metrics.cache_floor()} even when nothing was reused).
          Idle gap: time since the previous xAI call on the same conversation id ended.
        </p>

        <div class="min-w-0 overflow-x-auto">
          <table id="costs-sessions" class="w-full text-sm">
            <caption class="play-label pb-1 text-left text-[var(--paper-muted)]">
              Recent sessions
            </caption>
            <thead class="text-left text-[var(--paper-muted)]">
              <tr>
                <th class="py-1 pr-2 font-medium">Session</th>
                <th class="hidden py-1 pr-2 font-medium sm:table-cell">Adventure</th>
                <th class="py-1 pr-2 text-right font-medium">Turns</th>
                <th class="py-1 pr-2 text-right font-medium">Game</th>
                <th class="hidden py-1 pr-2 text-right font-medium sm:table-cell">/turn</th>
                <th class="py-1 pr-2 text-right font-medium">Persona</th>
                <th class="hidden py-1 pr-2 text-right font-medium md:table-cell">GM p50</th>
                <th class="py-1 text-right font-medium">GM cache</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-[var(--paper-rule)]">
              <tr :for={s <- @metrics.sessions} id={"costs-session-#{s.game_session_id}"}>
                <td class="whitespace-nowrap py-1 pr-2">
                  <.link
                    navigate={~p"/admin/play/sessions/#{s.game_session_id}"}
                    class="text-[var(--paper-accent)]"
                  >
                    {String.slice(s.game_session_id, 0, 8)}
                  </.link>
                  <span class="block text-xs text-[var(--paper-muted)]">
                    {stockholm_time(s.last_at)}
                  </span>
                </td>
                <td class="hidden py-1 pr-2 sm:table-cell">{s.adventure_id || "—"}</td>
                <td class="py-1 pr-2 text-right tabular-nums">{s.turns}</td>
                <td class="whitespace-nowrap py-1 pr-2 text-right tabular-nums">
                  {format_usd(s.game_cost_micro_usd)}
                </td>
                <td class="hidden whitespace-nowrap py-1 pr-2 text-right tabular-nums sm:table-cell">
                  {format_usd(s.game_cost_per_turn)}
                </td>
                <td class="whitespace-nowrap py-1 pr-2 text-right tabular-nums">
                  {format_usd(s.persona_cost_micro_usd)}
                </td>
                <td class="hidden whitespace-nowrap py-1 pr-2 text-right tabular-nums md:table-cell">
                  {format_latency(s.gm_p50_ms)}
                </td>
                <td class="whitespace-nowrap py-1 text-right tabular-nums">
                  {format_pct(s.gm_hit_rate)}
                  <span class="block text-xs text-[var(--paper-muted)]">
                    {s.gm_hits}/{s.gm_calls} hits
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
          <p :if={@metrics.sessions == []} class="text-sm text-[var(--paper-muted)]">
            No sessions this month.
          </p>
        </div>
      </.section_card>

      <%= case @playtest do %>
        <% {:ok, summary} -> %>
          <.runs_section
            id="costs-env-peer"
            title={"Playtest (#{summary["app"]})"}
            summary={summary}
            rate={@rate}
          />
        <% other -> %>
          <.section_card title="Playtest" id="costs-env-peer">
            <p class="text-sm text-[var(--paper-ink)]">{playtest_message(other)}</p>
          </.section_card>
      <% end %>

      <.section_card title="Fixed monthly costs (not in the grand total)" id="costs-fixed">
        <div class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead class="text-left text-[var(--paper-muted)]">
              <tr>
                <th class="py-1 pr-3 font-medium">Item</th>
                <th class="py-1 pr-3 text-right font-medium">USD/month</th>
                <th class="py-1 text-right font-medium">SEK/month</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-[var(--paper-rule)]">
              <tr :for={item <- @report.fixed} class="align-top">
                <td class="py-2 pr-3">
                  <div class="text-[var(--paper-ink)]">{item.name}</div>
                  <div :if={Costs.sek_per_year?(item)} class="text-xs text-[var(--paper-ink)]">
                    {format_sek_year(Costs.sek_per_year(item))}/year · monthly share ÷ 12
                  </div>
                  <div class="text-xs text-[var(--paper-muted)]">{item.source}</div>
                </td>
                <td class="whitespace-nowrap py-2 pr-3 text-right tabular-nums">{fixed_usd(item)}</td>
                <td class="whitespace-nowrap py-2 text-right tabular-nums">
                  {fixed_sek(item, @rate)}
                </td>
              </tr>
            </tbody>
            <tfoot>
              <tr class="border-t border-[var(--paper-rule)] font-semibold">
                <td class="py-2 pr-3">Known items</td>
                <td class="whitespace-nowrap py-2 pr-3 text-right tabular-nums">
                  {usd(@report.fixed_known_micro_usd)}
                </td>
                <td class="whitespace-nowrap py-2 text-right tabular-nums">
                  {sek(@report.fixed_known_micro_usd, @rate)}
                </td>
              </tr>
            </tfoot>
          </table>
        </div>
        <p class="text-xs text-[var(--paper-muted)]">
          Edit these figures in <code>config/config.exs</code>
          (<code>config :ex_tales_forge, TalesForge.Costs</code>).
          Items may be USD per month or SEK per year;
          SEK yearly ones are converted at the rate above and shown as yearly and as monthly share (÷ 12).
        </p>
      </.section_card>

      <.latency_card latency={@latency} />
    </Layouts.admin>
    """
  end

  attr :id, :string, default: nil
  attr :label, :string, required: true
  attr :micro, :integer, required: true
  attr :rate, :map, required: true
  attr :strong, :boolean, default: false

  defp money_row(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex flex-wrap items-baseline justify-between gap-x-4 py-2",
        @strong && "font-semibold"
      ]}
    >
      <dt class="min-w-0 text-[var(--paper-ink)]">{@label}</dt>
      <dd class="ml-auto whitespace-nowrap tabular-nums text-[var(--paper-ink)]">
        {usd(@micro)} <span class="text-[var(--paper-muted)]">· {sek(@micro, @rate)}</span>
      </dd>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true

  defp metric_row(assigns) do
    ~H"""
    <div id={@id} class="flex flex-wrap justify-between gap-x-3">
      <dt class="text-[var(--paper-muted)]">{@label}</dt>
      <dd class="ml-auto tabular-nums text-[var(--paper-ink)]">{@value}</dd>
    </div>
    """
  end

  attr :check, :map, required: true
  attr :rate, :map, required: true

  defp playtest_line(%{check: %{status: :over}} = assigns) do
    ~H"""
    <p
      id="costs-playtest-warning"
      role="alert"
      class="rounded border border-[var(--paper-danger-rule)] bg-[var(--paper-warn-bg)] px-3 py-2 text-sm text-[var(--paper-warn-ink)]"
    >
      Warning: playtest is projected at {usd(@check.total_micro_usd)}/month (fixed {usd(
        @check.fixed_micro_usd
      )} + AI {usd(@check.projected_ai_micro_usd)}), over the {usd(@check.threshold_micro_usd)} threshold.
    </p>
    """
  end

  defp playtest_line(%{check: %{status: :ok}} = assigns) do
    ~H"""
    <p id="costs-playtest-ok" class="text-sm text-[var(--paper-muted)]">
      Playtest is projected at {usd(@check.total_micro_usd)}/month (fixed {usd(@check.fixed_micro_usd)} + AI {usd(
        @check.projected_ai_micro_usd
      )}), under the {usd(@check.threshold_micro_usd)} threshold.
    </p>
    """
  end

  defp playtest_line(assigns) do
    ~H"""
    <p id="costs-playtest-unchecked" class="text-sm text-[var(--paper-muted)]">
      Playtest threshold ({usd(@check.threshold_micro_usd)}/month) not checked: no playtest AI numbers on this page.
    </p>
    """
  end

  attr :rate, :map, required: true
  slot :inner_block, required: true

  defp page_header(assigns) do
    ~H"""
    <header class="space-y-1">
      <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">Costs</h2>
      <p class="text-[var(--paper-muted)]">
        {render_slot(@inner_block)} Days and months run on Europe/Stockholm time, like the AI day cap.
      </p>
      <p id="costs-rate" class="text-sm text-[var(--paper-muted)]">
        1 USD = {format_rate(@rate.rate)} SEK (rate as of {Date.to_iso8601(@rate.as_of)}; {@rate.source})
      </p>
    </header>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :summary, :map, required: true, doc: "a TalesForge.Costs.PlaytestRuns summary"
  attr :rate, :map, required: true

  defp runs_section(assigns) do
    ~H"""
    <.section_card title={@title} id={@id}>
      <div class="grid gap-4 xl:grid-cols-2">
        <.runs_table id={"#{@id}-today"} caption="Today" window={@summary["today"]} rate={@rate} />
        <.runs_table
          id={"#{@id}-month"}
          caption={"This month · runs started: #{@summary["month"]["runs"]}"}
          window={@summary["month"]}
          rate={@rate}
        />
      </div>
      <dl class="text-sm">
        <.money_row
          id={"#{@id}-outside"}
          label="Not a playtest run (manual play etc.), this month: not in the runs' total"
          micro={@summary["month"]["outside_runs"]["cost_micro_usd"]}
          rate={@rate}
        />
      </dl>
      <p class="text-xs text-[var(--paper-muted)]">
        A call counts for a run when it is on the run's session. Game = GM, Jev intent (TypeSafe)
        and other game calls (scene, NPC reactions, LLM intent, ...). The persona bot and Jev
        scoring are the playtest bots and are never added to game cost.
        <span :if={@summary["generated_at"]}>
          As of {stockholm_time(@summary["generated_at"])} (Stockholm).
        </span>
      </p>
    </.section_card>
    """
  end

  attr :id, :string, required: true
  attr :caption, :string, required: true
  attr :window, :map, required: true
  attr :rate, :map, required: true

  defp runs_table(assigns) do
    assigns =
      assign(assigns,
        game: PlaytestRuns.game_lines(),
        bots: PlaytestRuns.bot_lines(),
        labels: @line_labels
      )

    ~H"""
    <div class="min-w-0 overflow-x-auto">
      <table class="w-full text-sm">
        <caption class="play-label pb-1 text-left text-[var(--paper-muted)]">{@caption}</caption>
        <thead class="text-left text-[var(--paper-muted)]">
          <tr>
            <th class="py-1 pr-2 font-medium">Line</th>
            <th class="py-1 pr-2 text-right font-medium">Calls</th>
            <th class="py-1 pr-2 text-right font-medium">USD</th>
            <th class="py-1 pr-2 text-right font-medium">SEK</th>
            <th class="py-1 text-right font-medium" title="capped / errors">Cap/err</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-[var(--paper-rule)]">
          <.runs_row
            :for={name <- @game}
            id={"#{@id}-#{name}"}
            label={@labels[name]}
            counts={@window["lines"][name]}
            rate={@rate}
          />
          <.subtotal_row
            id={"#{@id}-game"}
            label="Game"
            micro={@window["game_micro_usd"]}
            rate={@rate}
          />
          <.runs_row
            :for={name <- @bots}
            id={"#{@id}-#{name}"}
            label={@labels[name]}
            counts={@window["lines"][name]}
            rate={@rate}
          />
          <.subtotal_row
            id={"#{@id}-bots"}
            label="Bots"
            micro={@window["bots_micro_usd"]}
            rate={@rate}
          />
        </tbody>
        <tfoot>
          <.subtotal_row
            id={"#{@id}-total"}
            label="Runs total"
            micro={@window["runs_total_micro_usd"]}
            rate={@rate}
          />
        </tfoot>
      </table>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :counts, :map, required: true
  attr :rate, :map, required: true

  defp runs_row(assigns) do
    ~H"""
    <tr id={@id}>
      <td class="py-1 pr-2">{@label}</td>
      <td class="py-1 pr-2 text-right tabular-nums">{@counts["calls"]}</td>
      <td class="whitespace-nowrap py-1 pr-2 text-right tabular-nums">
        {usd(@counts["cost_micro_usd"])}
      </td>
      <td class="whitespace-nowrap py-1 pr-2 text-right tabular-nums">
        {sek(@counts["cost_micro_usd"], @rate)}
      </td>
      <td class="whitespace-nowrap py-1 text-right tabular-nums">
        {@counts["capped"]} / {@counts["errors"]}
      </td>
    </tr>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :micro, :integer, required: true
  attr :rate, :map, required: true

  defp subtotal_row(assigns) do
    ~H"""
    <tr id={@id} class="border-t border-[var(--paper-rule)] font-semibold">
      <td class="py-1 pr-2">{@label}</td>
      <td class="py-1 pr-2"></td>
      <td class="whitespace-nowrap py-1 pr-2 text-right tabular-nums">{usd(@micro)}</td>
      <td class="whitespace-nowrap py-1 pr-2 text-right tabular-nums">{sek(@micro, @rate)}</td>
      <td class="py-1"></td>
    </tr>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :summary, :map, required: true
  attr :rate, :map, required: true

  defp env_section(assigns) do
    ~H"""
    <.section_card title={@title} id={@id}>
      <div class="grid gap-4 xl:grid-cols-2">
        <.bucket_table
          id={"#{@id}-today"}
          caption="Today"
          buckets={@summary["today"]["buckets"]}
          rate={@rate}
        />
        <.bucket_table
          id={"#{@id}-month"}
          caption="This month"
          buckets={@summary["month"]["buckets"]}
          rate={@rate}
        />
      </div>
      <dl class="grid gap-x-6 gap-y-1 text-sm sm:grid-cols-2">
        <div class="flex flex-wrap justify-between gap-x-3">
          <dt class="text-[var(--paper-muted)]">Avg game cost per game session (month)</dt>
          <dd class="ml-auto tabular-nums">{avg_line(@summary["month"], @rate)}</dd>
        </div>
        <div class="flex flex-wrap justify-between gap-x-3">
          <dt class="text-[var(--paper-muted)]">AI projected to month end</dt>
          <dd class="ml-auto tabular-nums">
            {usd(@summary["month"]["projected_micro_usd"])} · {sek(
              @summary["month"]["projected_micro_usd"],
              @rate
            )}
          </dd>
        </div>
      </dl>
      <p :if={@summary["generated_at"]} class="text-xs text-[var(--paper-muted)]">
        As of {stockholm_time(@summary["generated_at"])} (Stockholm). Game = gm, intent and scene calls; persona and scorer are the playtest bots.
      </p>
    </.section_card>
    """
  end

  attr :id, :string, required: true
  attr :caption, :string, required: true
  attr :buckets, :map, required: true
  attr :rate, :map, required: true

  defp bucket_table(assigns) do
    ~H"""
    <div class="min-w-0 overflow-x-auto">
      <table class="w-full text-sm">
        <caption class="play-label pb-1 text-left text-[var(--paper-muted)]">{@caption}</caption>
        <thead class="text-left text-[var(--paper-muted)]">
          <tr>
            <th class="py-1 pr-2 font-medium">Bucket</th>
            <th class="py-1 pr-2 text-right font-medium">Calls</th>
            <th class="py-1 pr-2 text-right font-medium">USD</th>
            <th class="py-1 pr-2 text-right font-medium">SEK</th>
            <th class="py-1 text-right font-medium" title="capped / errors">Cap/err</th>
          </tr>
        </thead>
        <tbody class="divide-y divide-[var(--paper-rule)]">
          <tr
            :for={name <- TalesForge.AICalls.buckets()}
            id={"#{@id}-#{name}"}
          >
            <td class="py-1 pr-2">{name}</td>
            <td class="py-1 pr-2 text-right tabular-nums">{@buckets[name]["calls"]}</td>
            <td class="whitespace-nowrap py-1 pr-2 text-right tabular-nums">
              {usd(@buckets[name]["cost_micro_usd"])}
            </td>
            <td class="whitespace-nowrap py-1 pr-2 text-right tabular-nums">
              {sek(@buckets[name]["cost_micro_usd"], @rate)}
            </td>
            <td class="whitespace-nowrap py-1 text-right tabular-nums">
              {@buckets[name]["capped"]} / {@buckets[name]["errors"]}
            </td>
          </tr>
        </tbody>
        <tfoot>
          <tr class="border-t border-[var(--paper-rule)] font-semibold">
            <td class="py-1 pr-2">Total</td>
            <td class="py-1 pr-2 text-right tabular-nums">{sum_key(@buckets, "calls")}</td>
            <td class="whitespace-nowrap py-1 pr-2 text-right tabular-nums">
              {usd(sum_key(@buckets, "cost_micro_usd"))}
            </td>
            <td class="whitespace-nowrap py-1 pr-2 text-right tabular-nums">
              {sek(sum_key(@buckets, "cost_micro_usd"), @rate)}
            </td>
            <td class="whitespace-nowrap py-1 text-right tabular-nums">
              {sum_key(@buckets, "capped")} / {sum_key(@buckets, "errors")}
            </td>
          </tr>
        </tfoot>
      </table>
    </div>
    """
  end

  # --- formatting -------------------------------------------------------------

  defp sum_key(buckets, key), do: buckets |> Map.values() |> Enum.map(& &1[key]) |> Enum.sum()

  # Cents for amounts of a dollar or more; four decimals below that, so small AI
  # spend stays visible.
  defp usd(micro) when is_integer(micro) do
    decimals = if micro != 0 and abs(micro) < 1_000_000, do: 4, else: 2
    "$" <> :erlang.float_to_binary(micro / 1_000_000, decimals: decimals)
  end

  defp sek(micro, rate) when is_integer(micro) do
    :erlang.float_to_binary(Costs.to_sek(micro, rate.rate), decimals: 2) <> " kr"
  end

  defp format_rate(rate), do: :erlang.float_to_binary(rate / 1, [:compact, decimals: 4])

  defp fixed_usd(item) do
    case Costs.fixed_micro_usd(item) do
      :unknown -> "unknown"
      micro -> usd(micro)
    end
  end

  defp fixed_sek(item, rate) do
    case Costs.fixed_micro_usd(item) do
      :unknown -> "unknown"
      micro -> sek(micro, rate)
    end
  end

  defp format_sek_year(sek) when is_number(sek) do
    :erlang.float_to_binary(sek / 1, decimals: 2) <> " kr"
  end

  defp avg_line(%{"avg_game_micro_usd_per_session" => avg, "game_sessions" => n}, rate)
       when is_integer(avg) do
    "#{usd(avg)} · #{sek(avg, rate)} (#{n} #{if n == 1, do: "session", else: "sessions"})"
  end

  defp avg_line(_month, _rate), do: "— (no game sessions yet)"

  defp scope(%{playtest_included: true}), do: "production and playtest"
  defp scope(_report), do: "production only"

  defp playtest_short(:loading), do: "loading"
  defp playtest_short({:error, :not_configured}), do: "not configured"
  defp playtest_short(_error), do: "playtest unavailable"

  defp playtest_message(:loading), do: "Loading playtest numbers…"

  defp playtest_message({:error, :not_configured}) do
    "Playtest: not configured. Set the Fly secret COSTS_PEER_TOKEN to the same value " <>
      "on both apps (tales-forge and tales-forge-playtest)."
  end

  defp playtest_message({:error, reason}),
    do: "Playtest unavailable: #{reason_text(reason)}. Production's numbers above are complete."

  defp reason_text(:unreachable),
    do: "no answer within #{div(Peer.timeout_ms(), 1000)} s, or the connection failed"

  defp reason_text(:bad_response), do: "unexpected response (is playtest on the same version?)"
  defp reason_text({:http_status, 401}), do: "HTTP 401, token rejected"

  defp reason_text({:http_status, 404}),
    do: "HTTP 404, endpoint off there (no COSTS_PEER_TOKEN on playtest)"

  defp reason_text({:http_status, status}), do: "HTTP #{status}"
  defp reason_text(_reason), do: "error"

  defp cache_line(%{calls: 0}), do: "— (no calls)"

  defp cache_line(cache) do
    "#{format_pct(cache.hit_rate)} of input tokens · #{cache.hits}/#{cache.calls} calls hit"
  end

  defp stockholm_time(%DateTime{} = dt), do: stockholm_time(DateTime.to_iso8601(dt))

  defp stockholm_time(iso) do
    with {:ok, dt, _} <- DateTime.from_iso8601(iso),
         {:ok, local} <-
           DateTime.shift_zone(dt, "Europe/Stockholm", TimeZoneInfo.TimeZoneDatabase) do
      Calendar.strftime(local, "%Y-%m-%d %H:%M")
    else
      _ -> iso
    end
  end

  attr :latency, :map, required: true, doc: "`TalesForgeWeb.TeamLiveNumbers.intent_latency/2`"

  # Jev intent latency on this app, last 7 days (moved here from the founders'
  # presentation, admin split 2026-10-10: it is a property of each app's calls).
  defp latency_card(assigns) do
    ~H"""
    <.section_card title="Jev intent latency · last 7 days (this app)" id="costs-intent-latency">
      <%= if @latency.source == :live do %>
        <dl class="grid grid-cols-2 gap-x-6 gap-y-1 text-sm sm:grid-cols-4">
          <div>
            <dt class="text-[var(--paper-muted)]">Reads</dt>
            <dd id="latency-reads" class="font-semibold tabular-nums">{@latency.reads}</dd>
          </div>
          <div>
            <dt class="text-[var(--paper-muted)]">Median (p50)</dt>
            <dd id="latency-p50" class="font-semibold tabular-nums">{@latency.p50_ms} ms</dd>
          </div>
          <div>
            <dt class="text-[var(--paper-muted)]">p95</dt>
            <dd id="latency-p95" class="font-semibold tabular-nums">{@latency.p95_ms} ms</dd>
          </div>
          <div>
            <dt class="text-[var(--paper-muted)]">Slowest</dt>
            <dd id="latency-max" class="font-semibold tabular-nums">{@latency.max_ms} ms</dd>
          </div>
        </dl>
      <% else %>
        <p id="latency-none" class="text-sm text-[var(--paper-muted)]">
          This app made no Jev intent reads in the last 7 days.
        </p>
      <% end %>
    </.section_card>
    """
  end
end
