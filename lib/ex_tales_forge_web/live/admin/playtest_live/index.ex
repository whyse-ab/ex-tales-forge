defmodule TalesForgeWeb.AdminLive.PlaytestLive.Index do
  @moduledoc """
  Admin: playtest runs, and a form to start a new run with a persona.
  """

  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents

  alias TalesForge.Game.Variant
  alias TalesForge.Playtest.{Personas, Reports, RunMeta, Runner}
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
     |> assign(:rows, Reports.list_runs())
     |> assign(:now, DateTime.utc_now())}
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
          Persona bot sessions and their judge scores. Game cost and time leave out the bot's own calls.
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
              <td class="px-3 py-2">{overall(row.score)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.admin>
    """
  end

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
