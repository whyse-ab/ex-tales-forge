defmodule TalesForgeWeb.AdminLive.PlaytestLive.Show do
  @moduledoc """
  Admin: one playtest run, with its turns, scores, costs and timings, and how the
  characters changed over it (`TalesForge.Playtest.CharacterChanges`); refreshes
  while the run is going.
  """

  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents
  import TalesForgeWeb.CharacterChangesComponents

  alias TalesForge.Playtest.{CharacterChanges, JevHeadline, Reports, RunMeta, Runner, Scorer}
  alias TalesForgeWeb.TimeAgo

  @refresh_ms 3_000
  # Re-render the "N minutes ago" words this often, also once the run is done.
  @tick_ms 60_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Reports.get_run(id) do
      {:ok, run} ->
        if connected?(socket), do: :timer.send_interval(@tick_ms, :tick)

        {:ok,
         socket
         |> assign(:page_title, "Playtest run")
         |> assign(:enabled, Runner.enabled?())
         |> assign(:scoring, false)
         |> load(run)}

      {:error, :not_found} ->
        {:ok,
         socket |> put_flash(:error, "Run not found.") |> push_navigate(to: ~p"/admin/playtest")}
    end
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, assign(socket, :now, DateTime.utc_now())}

  def handle_info(:refresh, socket) do
    {:ok, run} = Reports.get_run(socket.assigns.run.id)
    {:noreply, load(socket, run)}
  end

  @impl true
  def handle_event("score", _params, socket) do
    run_id = socket.assigns.run.id

    {:noreply,
     socket
     |> assign(:scoring, true)
     |> start_async(:score, fn -> Scorer.score(run_id) end)}
  end

  @impl true
  def handle_async(:score, result, socket) do
    socket = socket |> assign(:scoring, false) |> load(socket.assigns.run)

    case result do
      {:ok, {:ok, _score}} ->
        {:noreply, put_flash(socket, :info, "Scored.")}

      {:ok, {:error, reason}} ->
        {:noreply, put_flash(socket, :error, "Scoring failed: #{inspect(reason)}")}

      {:exit, reason} ->
        {:noreply, put_flash(socket, :error, "Scoring failed: #{inspect(reason)}")}
    end
  end

  defp load(socket, run) do
    if run.status == "running" and connected?(socket),
      do: Process.send_after(self(), :refresh, @refresh_ms)

    socket
    |> assign(:now, DateTime.utc_now())
    |> assign(:run, run)
    |> assign(:opening, Reports.opening(run.game_session_id))
    |> assign(:turns, Reports.turn_records(run.game_session_id))
    |> assign(:metrics, Reports.metrics(run.game_session_id))
    |> assign(:score, Reports.latest_score(run.id))
    |> assign(:character_changes, CharacterChanges.for_session(run.game_session_id))
    |> assign_turn_affects(Reports.turn_affect_scores(run.id))
  end

  defp assign_turn_affects(socket, turn_affects) do
    socket
    |> assign(:turn_affects, turn_affects)
    |> assign(:jev, Reports.jev_headline(turn_affects))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active="playtest">
      <header class="space-y-2">
        <.link navigate={~p"/admin/playtest"} class="text-sm text-[var(--paper-accent)]">← Playtest runs</.link>
        <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">
          <span class="capitalize">{@run.persona}</span> · {@run.module}
        </h2>
        <p class="text-sm text-[var(--paper-muted)]">
          Build {@run.build || "—"} · started
          <.time_ago id="run-started" at={@run.started_at} now={@now} />
          ({TimeAgo.stockholm(@run.started_at)}) ·
          <.link
            navigate={~p"/admin/sessions/#{@run.game_session_id}"}
            class="text-[var(--paper-accent)]"
          >session</.link>
        </p>
        <p id="run-commit" class="text-sm text-[var(--paper-muted)]">
          Commit
          <.link
            :if={@run.git_sha}
            href={RunMeta.commit_url(@run.git_sha)}
            title={@run.git_sha}
            class="font-mono text-[var(--paper-accent)]"
          >{RunMeta.short_sha(@run.git_sha)}</.link>
          <span :if={is_nil(@run.git_sha)}>unknown</span>
        </p>
        <ul
          :if={@run.flags not in [nil, %{}]}
          id="run-flags"
          class="flex flex-wrap gap-2 text-xs"
        >
          <li
            :for={{name, value} <- Enum.sort(@run.flags)}
            class="rounded border border-[var(--paper-rule)] bg-[var(--paper-bg)] px-2 py-0.5 font-mono"
          >
            {name}={value}
          </li>
        </ul>
        <p :if={@run.notes} class="text-sm text-[var(--paper-muted)]">
          {@run.notes}
        </p>
      </header>

      <div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <.stat_card label="Status" value={status_text(@run)} />
        <.stat_card label="Turns" value={"#{@run.turns_played}/#{@run.turn_limit}"} />
        <.stat_card label="Game time" value={format_ms(@run.game_ms)} />
        <.stat_card label="Game cost" value={format_usd(@metrics.game.cost_micro_usd)} />
      </div>

      <.section_card title="Score" id="score">
        <%= if @score do %>
          <div :if={@score.source == "jev" and @jev} id="jev-headline" class="space-y-1">
            <p class="font-serif text-xl font-semibold text-[var(--paper-ink)]">
              {JevHeadline.format(@jev)}
              <span class="text-sm font-normal text-[var(--paper-muted)]">
                confidence-weighted over {@jev.turns} turns
              </span>
            </p>
            <p id="jev-breakdown" class="text-sm text-[var(--paper-ink)]">
              {JevHeadline.breakdown(@jev)}
              <span class="text-xs text-[var(--paper-muted)]">
                (confident = confidence ≥ {JevHeadline.unsure_below()}; high ≥ 3.5, low ≤ 2.5)
              </span>
            </p>
          </div>
          <p class={[
            "font-serif font-semibold text-[var(--paper-ink)]",
            if(@score.source == "jev" and @jev, do: "text-base", else: "text-xl")
          ]}>
            <span :if={@score.source == "jev" and @jev}>Session:</span> {score_headline(@score)}
          </p>
          <p class="text-xs text-[var(--paper-muted)]">
            {score_meta(@score)} ·
            <.time_ago id="score-scored-at" at={@score.inserted_at} now={@now} />
          </p>
          <p
            :if={@score.source == "jev" and @score.confidence}
            id="score-confidence"
            class="text-sm text-[var(--paper-ink)]"
          >
            Session confidence {Float.round(@score.confidence * 100, 1)}%
          </p>
          <div
            :if={@score.source == "jev" and @turn_affects != []}
            id="turn-affect-strip"
            class="flex flex-wrap gap-2 text-sm"
          >
            <span
              :for={ta <- @turn_affects}
              class="rounded border border-[var(--paper-rule)] bg-[var(--paper-bg)] px-2 py-1 tabular-nums"
              title={"confidence #{ta.confidence && Float.round(ta.confidence * 100, 1)}%"}
            >
              T{ta.turn_number}: {ta.overall || "—"}
            </span>
          </div>
          <ul :if={@score.source != "jev"} class="space-y-2 text-sm">
            <li
              :for={{criterion, result} <- Enum.sort(@score.scores)}
              class="rounded border border-[var(--paper-rule)] bg-[var(--paper-bg)] p-2"
            >
              <div class="flex gap-2">
                <span class="shrink-0 font-semibold">{result["score"] || "n/a"}</span>
                <span>{criterion}</span>
              </div>
              <p :if={result["evidence"]} class="mt-1 text-xs italic text-[var(--paper-muted)]">
                {result["evidence"]}
              </p>
            </li>
          </ul>
          <p :if={@score.rationale} class="text-sm text-[var(--paper-ink)]">{@score.rationale}</p>
        <% else %>
          <p class="text-sm text-[var(--paper-muted)]">Not scored.</p>
        <% end %>
        <button
          :if={@enabled and @run.status in ~w(finished stopped)}
          type="button"
          phx-click="score"
          disabled={@scoring}
          class="rounded bg-[var(--paper-accent)] px-4 py-2 text-sm text-[var(--paper-on-accent)] disabled:opacity-50"
        >
          {cond do
            @scoring -> "Scoring…"
            @score -> "Re-score"
            true -> "Score"
          end}
        </button>
      </.section_card>

      <.section_card title="Time" id="time">
        <dl class="grid gap-2 text-sm sm:grid-cols-3">
          <div>
            <dt class="play-label text-[var(--paper-muted)]">Game</dt>
            <dd>{format_ms(@run.game_ms)}</dd>
            <dd class="text-xs text-[var(--paper-muted)]">
              action submitted → turn done, plus scenes
            </dd>
          </div>
          <div>
            <dt class="play-label text-[var(--paper-muted)]">Persona (bot) thinking</dt>
            <dd>{format_ms(@run.persona_ms)}</dd>
          </div>
          <div>
            <dt class="play-label text-[var(--paper-muted)]">Wall clock, incl. bot</dt>
            <dd>{format_ms(wall_clock_ms(@run))}</dd>
          </div>
        </dl>
      </.section_card>

      <.section_card title="AI cost by call type" id="costs">
        <dl id="run-cache" class="grid gap-x-6 gap-y-1 text-sm sm:grid-cols-2">
          <div class="flex flex-wrap justify-between gap-x-3">
            <dt class="text-[var(--paper-muted)]">GM cache, turns 2+</dt>
            <dd id="run-cache-gm-later" class="ml-auto tabular-nums">
              {cache_line(@metrics.cache.gm_later)}
            </dd>
          </div>
          <div class="flex flex-wrap justify-between gap-x-3">
            <dt class="text-[var(--paper-muted)]">GM cache, all turns</dt>
            <dd class="ml-auto tabular-nums">{cache_line(@metrics.cache.gm)}</dd>
          </div>
          <div class="flex flex-wrap justify-between gap-x-3">
            <dt class="text-[var(--paper-muted)]">GM latency p50 / p90</dt>
            <dd id="run-gm-latency" class="ml-auto tabular-nums">
              {format_latency(@metrics.gm.p50_ms)} / {format_latency(@metrics.gm.p90_ms)}
            </dd>
          </div>
          <div class="flex flex-wrap justify-between gap-x-3">
            <dt class="text-[var(--paper-muted)]">GM idle gap p50 / p90</dt>
            <dd class="ml-auto tabular-nums">
              {format_latency(@metrics.idle_gap.p50_ms)} / {format_latency(@metrics.idle_gap.p90_ms)}
            </dd>
          </div>
          <div class="flex flex-wrap justify-between gap-x-3">
            <dt class="text-[var(--paper-muted)]">Game cost per turn</dt>
            <dd id="run-game-per-turn" class="ml-auto tabular-nums">
              {format_usd(@metrics.game_cost_per_turn)}
            </dd>
          </div>
          <div class="flex flex-wrap justify-between gap-x-3">
            <dt class="text-[var(--paper-muted)]">Persona (bot) cost</dt>
            <dd id="persona-line" class="ml-auto tabular-nums">
              {format_usd(@metrics.persona.cost_micro_usd)} · {@metrics.persona.calls} calls
            </dd>
          </div>
        </dl>
        <.call_breakdown id="run-breakdown" rows={@metrics.breakdown} />
        <p class="text-xs text-[var(--paper-muted)]">
          The session cap counts only the game; the persona has its own per-run cap and the day cap counts everything.
          Function rows are timed Elixir turn steps: free, and not counted as calls.
        </p>

        <div class="min-w-0 overflow-x-auto">
          <table id="run-per-turn" class="w-full text-sm">
            <caption class="play-label pb-1 text-left text-[var(--paper-muted)]">
              Per turn
            </caption>
            <thead class="text-left text-[var(--paper-muted)]">
              <tr>
                <th class="py-1 pr-2 font-medium">Turn</th>
                <th class="py-1 pr-2 text-right font-medium">GM</th>
                <th class="hidden py-1 pr-2 text-right font-medium sm:table-cell">Idle before</th>
                <th class="hidden py-1 pr-2 text-right font-medium md:table-cell">
                  In / cached / out
                </th>
                <th class="py-1 pr-2 text-right font-medium">Cache</th>
                <th class="py-1 pr-2 text-right font-medium">Game</th>
                <th class="hidden py-1 pr-2 text-right font-medium sm:table-cell">Persona</th>
                <th class="hidden py-1 text-right font-medium lg:table-cell">
                  Steps rules / prompt / persist
                </th>
              </tr>
            </thead>
            <tbody class="divide-y divide-[var(--paper-rule)]">
              <tr :for={t <- @metrics.per_turn} id={"run-turn-#{t.turn_number}"}>
                <td class="py-1 pr-2">{t.turn_number}</td>
                <td class="whitespace-nowrap py-1 pr-2 text-right tabular-nums">
                  {if t.gm_calls > 0, do: format_latency(t.gm_latency_ms), else: "—"}
                </td>
                <td class="hidden whitespace-nowrap py-1 pr-2 text-right tabular-nums sm:table-cell">
                  {format_latency(t.idle_gap_ms)}
                </td>
                <td class="hidden whitespace-nowrap py-1 pr-2 text-right tabular-nums md:table-cell">
                  {t.gm_input_tokens} / {t.gm_cached_tokens} / {t.gm_output_tokens}
                </td>
                <td class="whitespace-nowrap py-1 pr-2 text-right">
                  {cond do
                    t.gm_calls == 0 -> "—"
                    t.gm_hit -> "hit"
                    true -> "miss"
                  end}
                </td>
                <td class="whitespace-nowrap py-1 pr-2 text-right tabular-nums">
                  {format_usd(t.game_cost_micro_usd)}
                </td>
                <td class="hidden whitespace-nowrap py-1 pr-2 text-right tabular-nums sm:table-cell">
                  {format_usd(t.persona_cost_micro_usd)}
                </td>
                <td class="hidden whitespace-nowrap py-1 text-right tabular-nums lg:table-cell">
                  {step_ms(t.steps, "rules")} / {step_ms(t.steps, "prompt")} / {step_ms(
                    t.steps,
                    "persist"
                  )}
                </td>
              </tr>
            </tbody>
          </table>
          <p :if={@metrics.per_turn == []} class="text-sm text-[var(--paper-muted)]">
            No turns recorded yet.
          </p>
        </div>
      </.section_card>

      <.character_changes changes={@character_changes} />

      <.section_card title="Turns" id="turns">
        <article :if={@opening} id="turn-opening" class="space-y-1">
          <h3 class="play-label text-[var(--paper-muted)]">
            Opening · GM narration{if @opening.location_name, do: " · #{@opening.location_name}"}
          </h3>
          <p class="whitespace-pre-wrap text-sm text-[var(--paper-ink)]">{@opening.narrative}</p>
        </article>
        <p :if={@turns == []} class="text-sm text-[var(--paper-muted)]">No turns yet.</p>
        <article
          :for={turn <- @turns}
          id={"turn-#{turn.turn_number}"}
          class="grid gap-3 border-t border-[var(--paper-rule)] pt-3 md:grid-cols-2"
        >
          <div class="space-y-1">
            <h3 class="play-label text-[var(--paper-muted)]">Turn {turn.turn_number} · player saw</h3>
            <p class="text-sm font-medium text-[var(--paper-ink)]">{turn.player_action}</p>
            <p class="whitespace-pre-wrap text-sm text-[var(--paper-ink)]">{turn.narrative}</p>
          </div>
          <div class="space-y-1 rounded bg-[var(--paper-bg)] p-2">
            <h3 class="play-label text-[var(--paper-muted)]">Behind the screen</h3>
            <p class="text-sm">
              <span class="text-[var(--paper-muted)]">Roll:</span> {turn.roll || "none"}
            </p>
            <p class="text-sm text-[var(--paper-muted)]">GM notes:</p>
            <p class="whitespace-pre-wrap text-sm">{turn.gm_notes || "none recorded"}</p>
          </div>
        </article>
      </.section_card>
    </Layouts.admin>
    """
  end

  defp score_headline(%{source: "jev", overall: overall}) when is_number(overall),
    do: "#{overall}/5 persona affect"

  defp score_headline(%{overall: overall}) when is_number(overall), do: "#{overall}/5"
  defp score_headline(_score), do: "No criterion could be scored"

  defp score_meta(%{source: "jev"} = score),
    do: "Jev #{score.kind} · #{score.rubric_version} · #{score.model}"

  defp score_meta(score), do: "Rubric #{score.rubric_version} · #{score.model}"

  defp status_text(%{stop_reason: nil, status: status}), do: status
  defp status_text(%{stop_reason: reason, status: status}), do: "#{status} · #{reason}"

  defp cache_line(%{calls: 0}), do: "—"

  defp cache_line(cache),
    do: "#{format_pct(cache.hit_rate)} of input · #{cache.hits}/#{cache.calls} hit"

  defp step_ms(steps, name) do
    case steps[name] do
      nil -> "—"
      ms -> "#{ms} ms"
    end
  end

  defp wall_clock_ms(%{finished_at: nil}), do: nil
  defp wall_clock_ms(run), do: DateTime.diff(run.finished_at, run.started_at, :millisecond)
end
