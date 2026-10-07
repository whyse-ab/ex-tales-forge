defmodule TalesForgeWeb.AdminLive.PlaytestLive.Show do
  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents

  alias TalesForge.AICalls
  alias TalesForge.Playtest.{Reports, Runner, Scorer}

  @refresh_ms 3_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Reports.get_run(id) do
      {:ok, run} ->
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

    {game, bots} =
      run.game_session_id
      |> Reports.cost_by_purpose()
      |> Enum.split_with(&(&1.purpose not in AICalls.bot_purposes()))

    socket
    |> assign(:run, run)
    |> assign(:opening, Reports.opening(run.game_session_id))
    |> assign(:turns, Reports.turn_records(run.game_session_id))
    |> assign(:game_costs, game)
    |> assign(:game_total, total(game))
    |> assign(:scorer_cost, Enum.find(bots, &(&1.purpose == "scorer")))
    |> assign(:score, Reports.latest_score(run.id))
    |> assign(:turn_affects, Reports.turn_affect_scores(run.id))
  end

  defp total(rows) do
    Enum.reduce(
      rows,
      %{
        calls: 0,
        cost_micro_usd: 0,
        input_tokens: 0,
        output_tokens: 0,
        latency_ms: 0,
        capped: 0,
        errors: 0
      },
      fn row, acc ->
        Map.new(acc, fn {key, value} -> {key, value + Map.fetch!(row, key)} end)
      end
    )
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
          Build {@run.build || "—"} · started {Calendar.strftime(@run.started_at, "%Y-%m-%d %H:%M")} UTC ·
          <.link
            navigate={~p"/admin/sessions/#{@run.game_session_id}"}
            class="text-[var(--paper-accent)]"
          >session</.link>
        </p>
        <p :if={@run.notes} class="text-sm text-[var(--paper-muted)]">
          {@run.notes}
        </p>
      </header>

      <div class="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <.stat_card label="Status" value={status_text(@run)} />
        <.stat_card label="Turns" value={"#{@run.turns_played}/#{@run.turn_limit}"} />
        <.stat_card label="Game time" value={format_ms(@run.game_ms)} />
        <.stat_card label="Game cost" value={format_usd(@game_total.cost_micro_usd)} />
      </div>

      <.section_card title="Score" id="score">
        <%= if @score do %>
          <p class="font-serif text-xl font-semibold text-[var(--paper-ink)]">
            {score_headline(@score)}
          </p>
          <p class="text-xs text-[var(--paper-muted)]">
            {score_meta(@score)} · {Calendar.strftime(@score.inserted_at, "%Y-%m-%d %H:%M")} UTC
          </p>
          <p
            :if={@score.source == "jev" and @score.confidence}
            id="score-confidence"
            class="text-sm text-[var(--paper-ink)]"
          >
            Confidence {Float.round(@score.confidence * 100, 1)}%
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

      <.section_card title="AI cost" id="costs">
        <div class="overflow-x-auto">
          <table class="min-w-full text-sm">
            <thead class="text-left text-[var(--paper-muted)]">
              <tr>
                <th class="py-1 pr-3">Purpose</th>
                <th class="py-1 pr-3">Calls</th>
                <th class="hidden py-1 pr-3 sm:table-cell">Tokens in/out</th>
                <th class="hidden py-1 pr-3 sm:table-cell">Avg latency</th>
                <th class="py-1 pr-3">Cost</th>
                <th class="py-1 pr-3">Capped</th>
                <th class="py-1">Errors</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-[var(--paper-rule)]">
              <tr :for={row <- @game_costs}>
                <td class="py-1 pr-3">{row.purpose}</td>
                <.cost_cells row={row} />
              </tr>
              <tr class="font-semibold">
                <td class="py-1 pr-3">Game total</td>
                <.cost_cells row={@game_total} />
              </tr>
              <tr :if={@scorer_cost}>
                <td class="py-1 pr-3">Scorer</td>
                <.cost_cells row={@scorer_cost} />
              </tr>
              <tr id="persona-line">
                <td class="py-1 pr-3">Persona (bot)</td>
                <td class="py-1 pr-3">{@run.persona_calls}</td>
                <td class="hidden py-1 pr-3 sm:table-cell">
                  {@run.persona_input_tokens}/{@run.persona_output_tokens}
                </td>
                <td class="hidden py-1 pr-3 sm:table-cell">
                  {avg_ms(@run.persona_ms, @run.persona_calls)}
                </td>
                <td class="py-1 pr-3">{format_usd(@run.persona_cost_micro_usd)}</td>
                <td class="py-1 pr-3" colspan="2"></td>
              </tr>
            </tbody>
          </table>
        </div>
        <p class="text-xs text-[var(--paper-muted)]">
          The session cap counts only the game; the persona has its own per-run cap and the day cap counts everything.
        </p>
      </.section_card>

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

  attr :row, :map, required: true

  defp cost_cells(assigns) do
    ~H"""
    <td class="py-1 pr-3">{@row.calls}</td>
    <td class="hidden py-1 pr-3 sm:table-cell">{@row.input_tokens}/{@row.output_tokens}</td>
    <td class="hidden py-1 pr-3 sm:table-cell">{avg_ms(@row.latency_ms, @row.calls)}</td>
    <td class="py-1 pr-3">{format_usd(@row.cost_micro_usd)}</td>
    <td class="py-1 pr-3">{@row.capped}</td>
    <td class="py-1">{@row.errors}</td>
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

  defp avg_ms(_ms, 0), do: "—"
  defp avg_ms(ms, calls), do: format_ms(div(ms, calls))

  defp wall_clock_ms(%{finished_at: nil}), do: nil
  defp wall_clock_ms(run), do: DateTime.diff(run.finished_at, run.started_at, :millisecond)
end
