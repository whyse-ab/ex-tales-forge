defmodule TalesForgeWeb.AdminLive.CodeHeatLive do
  @moduledoc """
  The code heat map page (`/admin/operate/code-heat`), read-only.

  The page shows the newest daily sample of `TalesForge.CodeHeat` as a heat
  map. One tile is one app, one module or one function. The color shows the
  number of calls, the total time or the average time. The filters are a
  part of the module name and a minimum value. The highest tiles are hot
  spots. Modules that make AI calls have an "AI" mark. Below the map, the AI
  calls (Jev and LLM) of the last 24 hours show the number of calls and the
  time. The page shows no money.

  Each tile shows its value as text and a heat step (1 to 5) next to the
  color. The legend shows the color and the value range of each step. Hot
  spots have a "Hot" label and a flame icon. While there is no sample, the
  page shows the time of the first sample (Stockholm time) and the filters
  are disabled. On a narrow screen, each AI call is a stacked card; on a wide
  screen, the AI calls are a table.

  The filters are in the URL (`level`, `metric`, `module`, `min`).
  """

  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents, only: [section_card: 1]

  alias TalesForge.AppRole
  alias TalesForge.CodeHeat
  alias TalesForge.CodeHeat.Sampler

  @levels %{"app" => :app, "module" => :module, "function" => :function}
  @metrics %{"calls" => :calls, "total" => :total, "avg" => :avg}
  @max_tiles 300
  @steps 5

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    now = DateTime.utc_now()

    {:ok,
     socket
     |> assign(:page_title, "Code heat map")
     |> assign(:enabled, CodeHeat.enabled?())
     |> assign(:role, AppRole.role())
     |> assign(:snapshot, CodeHeat.latest())
     |> assign(:next_sample_at, Sampler.next_sample_at())
     |> assign(:ai_calls, CodeHeat.ai_calls(DateTime.add(now, -24, :hour)))}
  end

  @impl true
  @spec handle_params(map(), String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_params(params, _uri, socket) do
    level = Map.get(@levels, params["level"], :module)
    metric = Map.get(@metrics, params["metric"], :total)
    module = params |> Map.get("module", "") |> String.slice(0, 100)
    min = parse_min(params["min"])
    rows = if socket.assigns.snapshot, do: socket.assigns.snapshot.rows, else: []
    tiles = CodeHeat.tiles(rows, level, metric, module: module, min: min)

    {:noreply,
     socket
     |> assign(:level, level)
     |> assign(:metric, metric)
     |> assign(:module, module)
     |> assign(:min, min)
     |> assign(:tile_count, length(tiles))
     |> assign(:tiles, Enum.take(tiles, @max_tiles))
     |> assign(:legend, legend(tiles, metric))
     |> assign(:hot, Enum.filter(tiles, & &1.hot))}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("filter", params, socket) do
    query =
      params
      |> Map.take(~w(level metric module min))
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)

    {:noreply, push_patch(socket, to: ~p"/admin/operate/code-heat?#{query}")}
  end

  defp parse_min(nil), do: 0

  defp parse_min(text) do
    case Float.parse(String.trim(text)) do
      {n, _rest} when n > 0 -> n
      _ -> 0
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin socket={@socket} flash={@flash} active="code_heat">
      <header class="space-y-1">
        <h1 class="font-serif text-2xl font-semibold text-[var(--paper-ink)]">Code heat map</h1>
        <p class="text-sm text-[var(--paper-muted)]">
          The BEAM counts the calls and the time of each function in the app. A daily task writes one
          sample of the last 24 hours. The heat map runs on playtest only.
        </p>
      </header>

      <p :if={not @enabled} id="code-heat-off" class="alert alert-info text-sm">
        {off_text(@role)}
      </p>

      <.section_card id="code-heat-map" title="Heat map">
        <p :if={@snapshot} id="code-heat-sample" class="text-sm text-[var(--paper-muted)]">
          Sample from {format_time(@snapshot.started_at)} to {format_time(@snapshot.ended_at)} (Stockholm time): {@snapshot.modules} modules, {length(
            @snapshot.rows
          )} functions.
        </p>
        <p :if={is_nil(@snapshot)} id="code-heat-empty" class="text-sm">
          {empty_text(@next_sample_at)}
        </p>

        <form
          id="code-heat-filters"
          phx-change="filter"
          phx-submit="filter"
          class="grid grid-cols-1 gap-3 sm:grid-cols-4"
        >
          <fieldset disabled={is_nil(@snapshot)} class="contents">
            <label class="form-control">
              <span class="label-text text-sm">Level</span>
              <select name="level" class="select select-bordered select-sm min-h-11 w-full">
                <option
                  :for={{label, value} <- level_options()}
                  value={value}
                  selected={value == to_string(@level)}
                >
                  {label}
                </option>
              </select>
            </label>
            <label class="form-control">
              <span class="label-text text-sm">Color by</span>
              <select name="metric" class="select select-bordered select-sm min-h-11 w-full">
                <option
                  :for={{label, value} <- metric_options()}
                  value={value}
                  selected={value == to_string(@metric)}
                >
                  {label}
                </option>
              </select>
            </label>
            <label class="form-control">
              <span class="label-text text-sm">Module name</span>
              <input
                type="text"
                name="module"
                value={@module}
                placeholder="for example Game.Intent"
                phx-debounce="300"
                class="input input-bordered input-sm min-h-11 w-full"
              />
            </label>
            <label class="form-control">
              <span class="label-text text-sm">Minimum {metric_unit(@metric)}</span>
              <input
                type="number"
                name="min"
                min="0"
                step="any"
                value={if @min > 0, do: @min}
                phx-debounce="300"
                class="input input-bordered input-sm min-h-11 w-full"
              />
            </label>
          </fieldset>
          <p :if={is_nil(@snapshot)} class="text-xs text-[var(--paper-muted)] sm:col-span-4">
            The filters are available when the first sample is ready.
          </p>
        </form>

        <div :if={@hot != []} id="code-heat-hot" class="space-y-1">
          <h3 class="font-semibold text-[var(--paper-ink)]">Hot spots</h3>
          <ol class="list-decimal pl-5 text-sm">
            <li :for={tile <- @hot} class="break-all">
              <span aria-hidden="true">🔥</span>
              <span class="font-mono">{tile.label}</span>: {format_value(@metric, tile.value)}
            </li>
          </ol>
        </div>

        <p :if={@snapshot} class="text-xs text-[var(--paper-muted)]">
          {@tile_count} tiles. The color and the step use a log scale. Step 5 has the highest values.
        </p>

        <div :if={@legend != []} id="code-heat-legend" class="space-y-1">
          <h3 class="text-sm font-semibold text-[var(--paper-ink)]">
            Legend: {metric_label(@metric)}
          </h3>
          <ol class="flex flex-wrap gap-1.5 text-xs">
            <li
              :for={step <- @legend}
              id={"legend-step-#{step.step}"}
              style={tile_style(step.heat)}
              class="rounded-md px-2 py-1 tabular-nums"
            >
              <span class="font-semibold">Step {step.step}</span>: {step.range}
            </li>
          </ol>
          <p class="text-xs text-[var(--paper-muted)]">
            <span class="badge badge-error badge-xs">🔥 Hot</span>
            marks a hot spot. <span class="badge badge-info badge-xs">AI</span>
            marks a module that makes AI calls.
          </p>
        </div>

        <div
          id="code-heat-tiles"
          class="grid grid-cols-1 gap-1.5 sm:grid-cols-3 lg:grid-cols-4"
        >
          <div
            :for={tile <- @tiles}
            id={"tile-" <> tile_id(tile.key)}
            data-heat={tile.heat}
            data-step={step(tile.heat)}
            data-hot={to_string(tile.hot)}
            title={tile_title(tile)}
            style={tile_style(tile.heat)}
            class={[
              "min-w-0 rounded-md p-2 text-xs",
              tile.hot && "ring-2 ring-error ring-offset-1"
            ]}
          >
            <div class="flex items-start justify-between gap-1">
              <span class="break-all font-mono font-semibold">{tile.label}</span>
              <span class="flex shrink-0 gap-1">
                <span :if={tile.ai} class="badge badge-info badge-xs">AI</span>
                <span class="badge badge-ghost badge-xs bg-white/70 text-[#1f1b16]">
                  Step {step(tile.heat)}
                </span>
                <span :if={tile.hot} class="badge badge-error badge-xs">
                  <span aria-hidden="true">🔥</span> Hot
                </span>
              </span>
            </div>
            <div class="mt-1 font-semibold tabular-nums">
              {format_value(@metric, tile.value)}
            </div>
            <div class="tabular-nums">
              {format_int(tile.calls)} calls · {format_us(tile.time_us)} total · {format_us(
                tile.avg_us
              )} avg
            </div>
          </div>
        </div>
      </.section_card>

      <.section_card id="code-heat-ai" title="AI calls, last 24 hours">
        <p class="text-sm text-[var(--paper-muted)]">
          Jev and LLM calls on this app: the number of calls and the time.
        </p>
        <p :if={@ai_calls == []} class="text-sm">0 AI calls in the last 24 hours.</p>
        <ul :if={@ai_calls != []} id="code-heat-ai-cards" class="space-y-2 sm:hidden">
          <li
            :for={line <- @ai_calls}
            id={"ai-card-#{line.call_type}-#{tile_id(line.purpose)}"}
            class="rounded-md border border-[var(--paper-margin)] p-2 text-sm"
          >
            <div class="flex items-baseline justify-between gap-2">
              <span class="min-w-0 break-words font-mono"><.wrap_name name={line.purpose} /></span>
              <span class="badge badge-ghost badge-sm shrink-0">{line.call_type}</span>
            </div>
            <dl class="mt-1 grid grid-cols-3 gap-1 text-xs tabular-nums">
              <div>
                <dt class="text-[var(--paper-muted)]">Calls</dt>
                <dd>{format_int(line.calls)}</dd>
              </div>
              <div>
                <dt class="text-[var(--paper-muted)]">Total time</dt>
                <dd>{format_ms(line.total_ms)}</dd>
              </div>
              <div>
                <dt class="text-[var(--paper-muted)]">Average</dt>
                <dd>{format_ms(line.avg_ms)}</dd>
              </div>
            </dl>
          </li>
        </ul>
        <%!-- The wrapper hides the table below sm. The cards above show the same data
             there. The daisyUI table class sets display, so the hidden class goes on
             the wrapper and not on the table. --%>
        <div :if={@ai_calls != []} id="code-heat-ai-table-wrap" class="hidden sm:block">
          <table id="code-heat-ai-table" class="table table-sm">
            <thead>
              <tr>
                <th>Type</th>
                <th>Purpose</th>
                <th class="text-right">Calls</th>
                <th class="text-right">Total time</th>
                <th class="text-right">Average</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={line <- @ai_calls} id={"ai-#{line.call_type}-#{tile_id(line.purpose)}"}>
                <td>{line.call_type}</td>
                <td class="break-words font-mono"><.wrap_name name={line.purpose} /></td>
                <td class="text-right tabular-nums">{format_int(line.calls)}</td>
                <td class="text-right tabular-nums">{format_ms(line.total_ms)}</td>
                <td class="text-right tabular-nums">{format_ms(line.avg_ms)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.section_card>
    </Layouts.admin>
    """
  end

  attr :name, :string, required: true

  # Shows a name such as "npc_reaction" with a line-break point after each
  # underscore, so a narrow screen breaks the name at "npc_" and not in the
  # middle of a word. Each part is HTML-escaped before the join.
  defp wrap_name(assigns) do
    html =
      assigns.name
      |> to_string()
      |> String.split("_")
      |> Enum.map_join(
        "_<wbr>",
        &(&1 |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string())
      )

    assigns = assign(assigns, :html, Phoenix.HTML.raw(html))

    ~H"""
    {@html}
    """
  end

  defp off_text(:production),
    do: "The code heat map is off on production. It runs on playtest."

  defp off_text(_role),
    do: "The code heat map is off on this app. Set CODE_HEAT_MAP=on to turn it on."

  defp empty_text(nil),
    do: "There is no sample yet. The first sample comes 24 hours after the app starts."

  defp empty_text(%DateTime{} = at),
    do: "There is no sample yet. The first sample comes at #{format_time(at)} (Stockholm time)."

  defp metric_label(:calls), do: "calls"
  defp metric_label(:total), do: "total time"
  defp metric_label(:avg), do: "average time"

  # The heat step of a tile: 1 (cold) to 5 (hot).
  defp step(heat), do: min(@steps, floor(heat * @steps) + 1)

  # One legend line per step that has tiles: the step color and its value range.
  defp legend([], _metric), do: []

  defp legend(tiles, metric) do
    tiles
    |> Enum.group_by(&step(&1.heat))
    |> Enum.sort_by(fn {step, _tiles} -> step end)
    |> Enum.map(fn {step, in_step} ->
      values = Enum.map(in_step, & &1.value)

      %{
        step: step,
        heat: (step - 0.5) / @steps,
        range: range_text(metric, Enum.min(values), Enum.max(values))
      }
    end)
  end

  defp range_text(metric, low, high) when low == high, do: format_value(metric, low)

  defp range_text(metric, low, high),
    do: "#{format_value(metric, low)} to #{format_value(metric, high)}"

  defp level_options, do: [{"App", "app"}, {"Module", "module"}, {"Function", "function"}]

  defp metric_options,
    do: [{"Total time", "total"}, {"Calls", "calls"}, {"Average time", "avg"}]

  defp metric_unit(:calls), do: "calls"
  defp metric_unit(:total), do: "total time (µs)"
  defp metric_unit(:avg), do: "average time (µs)"

  defp format_value(:calls, value), do: "#{format_int(value)} calls"
  defp format_value(:total, value), do: format_us(value) <> " total"
  defp format_value(:avg, value), do: format_us(value) <> " average"

  @doc false
  @spec format_us(number()) :: String.t()
  def format_us(us) when us >= 1_000_000, do: "#{Float.round(us / 1_000_000, 2)} s"
  def format_us(us) when us >= 1_000, do: "#{Float.round(us / 1_000, 1)} ms"
  def format_us(us) when is_float(us), do: "#{Float.round(us, 1)} µs"
  def format_us(us), do: "#{us} µs"

  defp format_ms(ms) when ms >= 1_000, do: "#{Float.round(ms / 1_000, 2)} s"
  defp format_ms(ms), do: "#{ms} ms"

  defp format_int(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_int(n) when n >= 10_000, do: "#{Float.round(n / 1_000, 1)}k"
  defp format_int(n), do: to_string(n)

  defp format_time(%DateTime{} = at) do
    at
    |> DateTime.shift_zone!("Europe/Stockholm", TimeZoneInfo.TimeZoneDatabase)
    |> Calendar.strftime("%Y-%m-%d %H:%M")
  end

  defp tile_id(key), do: key |> String.replace(~r/[^A-Za-z0-9_-]+/, "-") |> String.trim("-")

  defp tile_title(tile),
    do: "#{tile.label}: #{tile.calls} calls, #{tile.time_us} µs total, heat #{tile.heat}"

  # Light yellow (cold) to dark red (hot). Dark text on light tiles.
  defp tile_style(heat) do
    hue = round(55 - 55 * heat)
    light = round(92 - 52 * heat)
    text = if light < 60, do: "#fff", else: "#1f1b16"
    "background-color: hsl(#{hue} 85% #{light}%); color: #{text};"
  end
end
