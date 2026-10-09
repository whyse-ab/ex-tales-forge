defmodule TalesForgeWeb.AdminLive.PlaytestLive.Index do
  @moduledoc """
  Admin: playtest runs, a form to start a new run with a persona, and the
  character changes per batch (`TalesForge.Playtest.CharacterChanges.batches/1`).

  On top, a founder-readable summary (`TalesForge.Playtest.Summary`): what we
  test and how, every batch of runs with its headline numbers per persona and
  links to its best and worst runs, and the main findings. The detailed run
  list follows below it.
  """

  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents
  import TalesForgeWeb.CharacterChangesComponents

  alias TalesForge.Collab.Markdown
  alias TalesForge.Game.Variant

  alias TalesForge.Playtest.{
    CharacterChanges,
    JevHeadline,
    Personas,
    Reports,
    RunMeta,
    Runner,
    Summary
  }

  alias TalesForgeWeb.TimeAgo

  # Re-render the "N minutes ago" words this often; the rows are not reloaded.
  @tick_ms 60_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@tick_ms, :tick)

    {:ok,
     socket
     |> assign(:page_title, "Playtest runs")
     |> assign(:enabled, Runner.enabled?())
     |> assign(:personas, Enum.map(Personas.list(), &{"#{&1.name} (#{&1.style})", &1.id}))
     |> assign(:modules, Runner.modules())
     |> assign(:variants, Variant.all())
     |> assign(
       :form,
       to_form(%{
         "persona" => "paul",
         "module" => "tin_valley",
         "turn_limit" => "5",
         "variant" => "default"
       })
     )
     |> assign_summary()
     |> assign_rows(Reports.list_runs())
     |> assign(:now, DateTime.utc_now())}
  end

  defp assign_rows(socket, rows) do
    socket
    |> assign(:rows, rows)
    |> assign(:batches, CharacterChanges.batches(Enum.map(rows, & &1.run)))
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, assign(socket, :now, DateTime.utc_now())}

  @impl true
  def handle_event("start", %{"persona" => persona, "module" => module} = params, socket) do
    turn_limit =
      case Integer.parse(params["turn_limit"] || "") do
        {n, ""} when n in 1..30 -> n
        _ -> 5
      end

    opts = [turn_limit: turn_limit, variant: params["variant"], notes: "started from admin"]

    case Runner.start(persona, module, opts) do
      {:ok, run_id} ->
        {:noreply, push_navigate(socket, to: ~p"/admin/playtest/#{run_id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not start the run: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active="playtest">
      <header>
        <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">Playtest runs</h2>
        <p class="text-sm text-[var(--paper-muted)]">
          A plain-language summary first; every run in detail <a
            href="#run-details"
            class="text-[var(--paper-accent)] underline"
          >further down</a>.
        </p>
      </header>

      <.summary summary={@summary} local_runs={@local_runs} />

      <header id="run-details" class="scroll-mt-4 border-t border-[var(--paper-rule)] pt-4">
        <h2 class="font-serif text-xl font-bold text-[var(--paper-ink)]">All runs, in detail</h2>
        <p class="text-sm text-[var(--paper-muted)]">
          Persona bot sessions and their judge scores. Game cost and time leave out the bot's own calls.
          The Jev score is the confidence-weighted turn average with the share of unsure turns
          (confidence below {JevHeadline.unsure_below()}) next to it.
        </p>
      </header>

      <.section_card :if={@enabled} title="Start a run" id="start-run">
        <.form
          for={@form}
          id="start-run-form"
          phx-submit="start"
          class="grid gap-3 sm:grid-cols-5 sm:items-end"
        >
          <.input field={@form[:persona]} type="select" label="Persona" options={@personas} />
          <.input field={@form[:module]} type="select" label="Module" options={@modules} />
          <.input field={@form[:variant]} type="select" label="Variant" options={@variants} />
          <.input field={@form[:turn_limit]} type="number" label="Turn limit" min="1" max="30" />
          <button
            type="submit"
            class="mb-2 rounded bg-[var(--paper-accent)] px-4 py-2 text-sm text-[var(--paper-on-accent)]"
          >
            Start run
          </button>
        </.form>
      </.section_card>

      <p :if={@rows == []} class="text-sm text-[var(--paper-muted)]">No runs yet.</p>

      <.batch_character_changes :if={@rows != []} batches={@batches} />

      <div :if={@rows != []} class="overflow-x-auto rounded-lg border border-[var(--paper-rule)]">
        <table class="min-w-full divide-y divide-[var(--paper-rule)] text-sm">
          <thead class="bg-[var(--paper-panel)] text-left text-[var(--paper-muted)]">
            <tr>
              <th class="px-3 py-2">Persona</th>
              <th class="hidden px-3 py-2 sm:table-cell">Module</th>
              <th class="hidden px-3 py-2 md:table-cell">Commit · flags</th>
              <th class="px-3 py-2">Status</th>
              <th class="px-3 py-2">Turns</th>
              <th class="hidden px-3 py-2 sm:table-cell">Game time</th>
              <th class="px-3 py-2">Game cost</th>
              <th class="hidden px-3 py-2 sm:table-cell">Persona cost</th>
              <th class="px-3 py-2">Score</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-[var(--paper-rule)] bg-[var(--paper-bg)]">
            <tr :for={row <- @rows} id={"run-#{row.run.id}"}>
              <td class="px-3 py-2">
                <.link
                  navigate={~p"/admin/playtest/#{row.run.id}"}
                  class="font-medium text-[var(--paper-accent)]"
                >
                  {row.run.persona}
                </.link>
                <div class="text-xs text-[var(--paper-muted)] sm:whitespace-nowrap">
                  <.time_ago id={"run-#{row.run.id}-started"} at={row.run.started_at} now={@now} />
                  <span class="hidden sm:inline">
                    · {TimeAgo.stockholm(row.run.started_at, "%m-%d %H:%M")}
                  </span>
                </div>
                <div class="text-xs text-[var(--paper-muted)] sm:hidden">{row.run.module}</div>
              </td>
              <td class="hidden px-3 py-2 sm:table-cell">{row.run.module}</td>
              <td class="hidden max-w-[12rem] px-3 py-2 text-xs md:table-cell" title={row.run.build}>
                <span class="font-mono">{RunMeta.short_sha(row.run.git_sha) || "—"}</span>
                <div :if={row.run.flags not in [nil, %{}]} class="text-[var(--paper-muted)]">
                  {flags_line(row.run.flags)}
                </div>
              </td>
              <td class="px-3 py-2">
                {row.run.status}
                <div :if={row.run.stop_reason} class="text-xs text-[var(--paper-muted)]">
                  {row.run.stop_reason}
                </div>
              </td>
              <td class="px-3 py-2">{row.run.turns_played}/{row.run.turn_limit}</td>
              <td class="hidden px-3 py-2 sm:table-cell">{format_ms(row.run.game_ms)}</td>
              <td class="px-3 py-2">{format_usd(row.game_cost_micro_usd)}</td>
              <td class="hidden px-3 py-2 sm:table-cell">
                {format_usd(row.run.persona_cost_micro_usd)}
              </td>
              <td class="px-3 py-2">
                <%= if row.jev do %>
                  <span id={"run-#{row.run.id}-jev"} class="whitespace-nowrap tabular-nums">
                    {JevHeadline.format(row.jev)}
                  </span>
                  <div class="text-xs text-[var(--paper-muted)] sm:whitespace-nowrap">
                    {JevHeadline.breakdown(row.jev)}
                  </div>
                  <div :if={row.score} class="text-xs text-[var(--paper-muted)]">
                    session {overall(row.score)}
                  </div>
                <% else %>
                  {overall(row.score)}
                <% end %>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.admin>
    """
  end

  # The curated summary plus live series numbers; nil if the files can't be read
  # (the page then just says so and shows the runs). `:local_runs`: which of its
  # best and worst runs are on this server (the others link to playtest).
  defp assign_summary(socket) do
    case Summary.current() do
      {:ok, summary} ->
        socket
        |> assign(:summary, summary)
        |> assign(:local_runs, Summary.local_run_ids(summary.batches))

      {:error, _reason} ->
        socket |> assign(:summary, nil) |> assign(:local_runs, MapSet.new())
    end
  end

  attr :summary, :map, default: nil
  attr :local_runs, :any, default: MapSet.new()

  defp summary(%{summary: nil} = assigns) do
    ~H"""
    <p id="playtest-summary-missing" class="text-sm text-[var(--paper-muted)]">
      The playtest summary could not be loaded.
    </p>
    """
  end

  defp summary(assigns) do
    ~H"""
    <section id="playtest-summary" class="space-y-4">
      <article
        id="summary-intro"
        class="prose prose-sm max-w-[80ch] rounded-lg border border-[var(--paper-rule)] bg-[var(--paper-panel)] p-4 text-[var(--paper-ink)]"
      >
        {Markdown.to_html(@summary.intro)}
      </article>

      <section id="summary-batches" class="space-y-3">
        <h2 class="font-serif text-xl font-bold text-[var(--paper-ink)]">The batches so far</h2>
        <p class="max-w-[80ch] text-sm text-[var(--paper-muted)]">
          <strong>Score:</strong>
          the judge's average for the whole game, from 1 (frustrated) to 5 (delighted); for Ronny, 5 means the game held firm against his tricks.
          <strong>Lead by turn 2:</strong>
          share of games where the game offered a job, a name or a place within the first two turns.
          <strong>Brush-offs:</strong>
          share of turns where someone in the game brushed the player off. <strong>Cost:</strong>
          AI cost of one game, including the bot player.
        </p>
        <.batch :for={batch <- @summary.batches} batch={batch} local_runs={@local_runs} />
      </section>

      <article
        :if={@summary.findings != ""}
        id="summary-findings"
        class="prose prose-sm max-w-[80ch] rounded-lg border border-[var(--paper-rule)] bg-[var(--paper-panel)] p-4 text-[var(--paper-ink)]"
      >
        {Markdown.to_html(@summary.findings)}
      </article>
    </section>
    """
  end

  attr :batch, :map, required: true
  attr :local_runs, :any, required: true

  defp batch(assigns) do
    ~H"""
    <article
      id={"batch-#{@batch.id}"}
      class="space-y-2 rounded-lg border border-[var(--paper-rule)] bg-[var(--paper-panel)] p-4"
    >
      <h3 class="font-serif text-lg font-semibold text-[var(--paper-ink)]">{@batch.title}</h3>
      <p class="text-xs text-[var(--paper-muted)]">
        <span>{@batch.date || "date to come"}</span>
        ·
        <span id={"batch-#{@batch.id}-commit"}>
          <%= if @batch.commit do %>
            commit
            <a
              href={RunMeta.commit_url(@batch.commit)}
              class="font-mono text-[var(--paper-accent)]"
            >{RunMeta.short_sha(@batch.commit)}</a>
          <% else %>
            {@batch.commit_note || "commit unknown"}
          <% end %>
        </span>
        · <span id={"batch-#{@batch.id}-runs"}>{runs_text(@batch)}</span>
        · <span id={"batch-#{@batch.id}-source"}>{source_text(@batch)}</span>
        <span :if={@batch.analysis}>
          ·
          <a href={@batch.analysis} class="text-[var(--paper-accent)] underline">written analysis</a>
        </span>
      </p>
      <p :if={@batch.game} class="max-w-[80ch] text-sm text-[var(--paper-ink)]">
        <strong>What the game was like:</strong> {@batch.game}
      </p>
      <p :if={@batch.changes} class="max-w-[80ch] text-sm text-[var(--paper-ink)]">
        <strong>What changed:</strong> {@batch.changes}
      </p>
      <p :if={overall_text(@batch.overall) != ""} class="text-sm text-[var(--paper-ink)]">
        <strong>All personas:</strong> {overall_text(@batch.overall)}
      </p>

      <p :if={@batch.personas == []} class="text-sm text-[var(--paper-muted)]">
        No numbers yet: none of this batch's runs have finished on this server.
      </p>

      <div
        :if={@batch.personas != []}
        class="overflow-x-auto rounded border border-[var(--paper-rule)]"
      >
        <table class="min-w-full divide-y divide-[var(--paper-rule)] text-sm">
          <thead class="bg-[var(--paper-bg)] text-left text-[var(--paper-muted)]">
            <tr>
              <th class="px-3 py-2">Persona</th>
              <th class="px-3 py-2">Score</th>
              <th class="px-3 py-2">Runs</th>
              <th class="hidden px-3 py-2 sm:table-cell">Lead by turn 2</th>
              <th class="hidden px-3 py-2 sm:table-cell">Brush-offs</th>
              <th class="hidden px-3 py-2 sm:table-cell">Cost</th>
              <th class="px-3 py-2">Best run</th>
              <th class="px-3 py-2">Worst run</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-[var(--paper-rule)]">
            <tr :for={{persona, stats} <- @batch.personas} id={"batch-#{@batch.id}-#{persona}"}>
              <td class="px-3 py-2 font-medium">
                {Summary.persona_name(persona)}
                <div :if={persona == "ronny"} class="text-xs font-normal text-[var(--paper-muted)]">
                  cheater test
                </div>
              </td>
              <td class="px-3 py-2">{score(stats.mean)}</td>
              <td class="px-3 py-2">{stats.runs || "—"}</td>
              <td class="hidden px-3 py-2 sm:table-cell">{pct(stats.hook_by_turn_2)}</td>
              <td class="hidden px-3 py-2 sm:table-cell">{pct(stats.brush_off)}</td>
              <td class="hidden px-3 py-2 sm:table-cell">{usd(stats.cost_per_run_usd)}</td>
              <td class="px-3 py-2">
                <.run_link id={stats.best} score={stats.best_score} local_runs={@local_runs} />
              </td>
              <td class="px-3 py-2">
                <.run_link id={stats.worst} score={stats.worst_score} local_runs={@local_runs} />
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <p :if={@batch.notes} class="max-w-[80ch] text-xs text-[var(--paper-muted)]">{@batch.notes}</p>
    </article>
    """
  end

  attr :id, :string, default: nil
  attr :score, :any, default: nil
  attr :local_runs, :any, default: MapSet.new()

  defp run_link(%{id: nil} = assigns), do: ~H"—"

  # A run on this server opens in place; a curated run that isn't here (e.g. on
  # production) opens on the playtest server instead of "Run not found".
  defp run_link(assigns) do
    ~H"""
    <.link
      :if={MapSet.member?(@local_runs, @id)}
      navigate={Summary.run_url(@id, @local_runs)}
      class="text-[var(--paper-accent)] underline"
    >
      {score(@score)}
    </.link>
    <a
      :if={!MapSet.member?(@local_runs, @id)}
      href={Summary.run_url(@id, @local_runs)}
      class="text-[var(--paper-accent)] underline"
    >
      {score(@score)}
    </a>
    """
  end

  # A running batch counts up to its plan; a finished one says how many runs its
  # numbers rest on, and the plan when it fell short of it.
  defp runs_text(%{status: :running, source: :curated, personas: [], planned_runs: planned})
       when is_integer(planned),
       do: "#{planned} runs planned"

  defp runs_text(%{status: :running, runs: runs, planned_runs: planned})
       when is_integer(runs) and is_integer(planned) and planned > runs,
       do: "#{runs} of #{planned} runs done so far"

  defp runs_text(%{status: :done, runs: runs, planned_runs: planned})
       when is_integer(runs) and is_integer(planned) and planned > runs,
       do: "#{runs} of #{planned} planned runs done"

  defp runs_text(%{runs: nil}), do: "runs to come"
  defp runs_text(%{runs: 1}), do: "1 run"
  defp runs_text(%{runs: runs}), do: "#{runs} runs"

  defp source_text(%{source: :live}), do: "numbers live from the runs on this server"
  defp source_text(%{personas: []}), do: "numbers to come"
  defp source_text(_batch), do: "numbers from the written analysis"

  defp overall_text(overall) do
    [
      overall.hook_by_turn_2 && "a lead by turn 2 in #{pct(overall.hook_by_turn_2)} of games",
      overall.brush_off && "brush-offs on #{pct(overall.brush_off)} of turns",
      overall.cost_per_run_usd && "about #{usd(overall.cost_per_run_usd)} per game"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp score(nil), do: "—"
  defp score(value), do: :erlang.float_to_binary(value / 1, decimals: 2)

  defp pct(nil), do: "—"
  defp pct(ratio) when ratio < 0.1, do: :erlang.float_to_binary(ratio * 100, decimals: 1) <> "%"
  defp pct(ratio), do: "#{round(ratio * 100)}%"

  defp usd(nil), do: "—"
  defp usd(value), do: "$" <> :erlang.float_to_binary(value / 1, decimals: 2)

  # The flags that tell runs apart at a glance; the run page lists them all.
  defp flags_line(flags) do
    [
      flags["variant"],
      flags["npc_reactions"] == "on" && "reactions",
      flags["world_agents"] == "on" && "agents"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" · ")
  end

  defp overall(nil), do: "—"
  defp overall(%{overall: nil}), do: "n/a"
  defp overall(%{overall: overall}), do: "#{overall}/5"
end
