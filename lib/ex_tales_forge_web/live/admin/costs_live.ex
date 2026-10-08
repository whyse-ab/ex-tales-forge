defmodule TalesForgeWeb.AdminLive.CostsLive do
  @moduledoc """
  Admin costs page: AI spend for this app and its peer (production and
  playtest), fixed monthly costs from config, USD with SEK alongside, the month
  total with an AI projection, and the playtest threshold warning. Read-only.
  """

  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents,
    only: [section_card: 1, call_breakdown: 1, format_latency: 1, format_pct: 1, format_usd: 1]

  alias TalesForge.AICalls
  alias TalesForge.AICalls.Metrics
  alias TalesForge.Costs
  alias TalesForge.Costs.Peer

  @impl true
  def mount(_params, _session, socket) do
    now = DateTime.utc_now()
    local = Costs.ai_summary(now)
    configured? = Peer.url() != nil and Peer.token() != nil

    peer = if configured?, do: :loading, else: {:error, :not_configured}

    socket =
      if configured? and connected?(socket),
        do: start_async(socket, :peer, fn -> Peer.fetch() end),
        else: socket

    {:ok,
     socket
     |> assign(:page_title, "Costs")
     |> assign(:local, local)
     |> assign(:peer_label, Costs.peer_label(local["app"]))
     |> assign(:rate, Costs.usd_sek())
     |> assign(:metrics, Metrics.period(AICalls.month_start(now), now))
     |> assign_peer(peer)}
  end

  @impl true
  def handle_async(:peer, {:ok, result}, socket), do: {:noreply, assign_peer(socket, result)}

  def handle_async(:peer, {:exit, _reason}, socket),
    do: {:noreply, assign_peer(socket, {:error, :unreachable})}

  defp assign_peer(socket, peer) do
    report_peer = if peer == :loading, do: {:error, :loading}, else: peer

    socket
    |> assign(:peer, peer)
    |> assign(:report, Costs.report(socket.assigns.local, report_peer))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active="costs">
      <header class="space-y-1">
        <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">Costs</h2>
        <p class="text-[var(--paper-muted)]">
          Read-only. AI spend from each environment's <code>ai_calls</code>; fixed costs from config.
          Days and months run on Europe/Stockholm time, like the AI day cap.
        </p>
        <p id="costs-rate" class="text-sm text-[var(--paper-muted)]">
          1 USD = {format_rate(@rate.rate)} SEK (rate as of {Date.to_iso8601(@rate.as_of)}; {@rate.source})
        </p>
      </header>

      <.section_card title="This month" id="costs-total">
        <dl class="divide-y divide-[var(--paper-rule)] text-sm">
          <.money_row
            label="Fixed costs (known items)"
            micro={@report.fixed_known_micro_usd}
            rate={@rate}
          />
          <.money_row
            label={"AI spend so far (#{ai_scope(@report, @peer_label)})"}
            micro={@report.ai_month_micro_usd}
            rate={@rate}
          />
          <.money_row label="Total so far" micro={@report.total_so_far_micro_usd} rate={@rate} strong />
          <.money_row
            label="AI projected to month end"
            micro={@report.ai_projected_micro_usd}
            rate={@rate}
          />
          <.money_row
            label="Projected month total"
            micro={@report.total_projected_micro_usd}
            rate={@rate}
            strong
          />
        </dl>
        <p class="text-xs text-[var(--paper-muted)]">
          Projection: AI spend this month / days elapsed ({@local["day_of_month"]}) * days in month ({@local[
            "days_in_month"
          ]}). Fixed costs are monthly list prices.
        </p>
        <p :if={@report.unknown != []} id="costs-unknown-note" class="text-sm text-[var(--paper-ink)]">
          Unknown items are excluded from these totals: {Enum.join(@report.unknown, ", ")}.
        </p>
        <p
          :if={!@report.peer_included}
          id="costs-peer-excluded"
          class="text-sm text-[var(--paper-muted)]"
        >
          {String.capitalize(@peer_label)} AI spend is not included ({peer_short(@peer)}).
        </p>
        <.playtest_line check={@report.playtest} rate={@rate} />
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
          <.metric_row
            id="costs-player-quote"
            label="GM quote fallback (intent safety read)"
            value={player_quote_line(@metrics.player_quote)}
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
                    navigate={~p"/admin/sessions/#{s.game_session_id}"}
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

      <%= case @peer do %>
        <% {:ok, summary} -> %>
          <.env_section
            id="costs-env-peer"
            summary={summary}
            rate={@rate}
            title={Costs.env_label(summary["app"])}
          />
        <% other -> %>
          <.section_card title={String.capitalize(@peer_label)} id="costs-env-peer">
            <p class="text-sm text-[var(--paper-ink)]">{peer_message(other, @peer_label)}</p>
          </.section_card>
      <% end %>

      <.section_card title="Fixed monthly costs" id="costs-fixed">
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
    </Layouts.admin>
    """
  end

  attr :label, :string, required: true
  attr :micro, :integer, required: true
  attr :rate, :map, required: true
  attr :strong, :boolean, default: false

  defp money_row(assigns) do
    ~H"""
    <div class={[
      "flex flex-wrap items-baseline justify-between gap-x-4 py-2",
      @strong && "font-semibold"
    ]}>
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

  defp ai_scope(%{peer_included: true}, _peer_label), do: "both environments"
  defp ai_scope(_report, _peer_label), do: "this app only"

  defp peer_short(:loading), do: "loading"
  defp peer_short({:error, :not_configured}), do: "not configured"
  defp peer_short(_error), do: "unavailable"

  defp peer_message(:loading, label), do: "Loading #{label} numbers…"

  defp peer_message({:error, :not_configured}, label) do
    "#{String.capitalize(label)}: not configured. Set COSTS_PEER_URL and COSTS_PEER_TOKEN on this app " <>
      "and the same COSTS_PEER_TOKEN on #{label}."
  end

  defp peer_message({:error, reason}, label),
    do: "#{String.capitalize(label)} unavailable: #{reason_text(reason)}."

  defp reason_text(:unreachable), do: "no answer within 3 s, or the connection failed"
  defp reason_text(:bad_response), do: "unexpected response"
  defp reason_text({:http_status, 401}), do: "HTTP 401, token rejected"
  defp reason_text({:http_status, 404}), do: "HTTP 404, endpoint off there (no COSTS_PEER_TOKEN)"
  defp reason_text({:http_status, status}), do: "HTTP #{status}"
  defp reason_text(_reason), do: "error"

  defp cache_line(%{calls: 0}), do: "— (no calls)"

  defp cache_line(cache) do
    "#{format_pct(cache.hit_rate)} of input tokens · #{cache.hits}/#{cache.calls} calls hit"
  end

  defp player_quote_line(%{reads: 0}), do: "— (no turns)"

  defp player_quote_line(pq) do
    reasons =
      pq.reasons
      |> Enum.sort_by(fn {_reason, n} -> -n end)
      |> Enum.map_join(", ", fn {reason, n} -> "#{reason} #{n}" end)

    "#{format_pct(pq.fallback_rate)} · #{pq.fallbacks}/#{pq.reads} turns got the summary" <>
      if(reasons == "", do: "", else: " (#{reasons})")
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
end
