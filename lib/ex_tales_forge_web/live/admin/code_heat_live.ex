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

  The filters are in the URL (`level`, `metric`, `module`, `min`).
  """

  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents, only: [section_card: 1]

  alias TalesForge.AppRole
  alias TalesForge.CodeHeat

  @levels %{"app" => :app, "module" => :module, "function" => :function}
  @metrics %{"calls" => :calls, "total" => :total, "avg" => :avg}
  @max_tiles 300

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
          The first sample comes 24 hours after the app starts.
        </p>

        <form
          id="code-heat-filters"
          phx-change="filter"
          phx-submit="filter"
          class="grid grid-cols-1 gap-3 sm:grid-cols-4"
        >
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
        </form>

        <div :if={@hot != []} id="code-heat-hot" class="space-y-1">
          <h3 class="font-semibold text-[var(--paper-ink)]">Hot spots</h3>
          <ol class="list-decimal pl-5 text-sm">
            <li :for={tile <- @hot} class="break-all">
              <span class="font-mono">{tile.label}</span>: {format_value(@metric, tile.value)}
            </li>
          </ol>
        </div>

        <p class="text-xs text-[var(--paper-muted)]">
          {@tile_count} tiles. The color uses a log scale. The darkest tile has the highest value.
        </p>

        <div
          id="code-heat-tiles"
          class="grid grid-cols-1 gap-1.5 sm:grid-cols-3 lg:grid-cols-4"
        >
          <div
            :for={tile <- @tiles}
            id={"tile-" <> tile_id(tile.key)}
            data-heat={tile.heat}
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
                <span :if={tile.hot} class="badge badge-error badge-xs">Hot</span>
              </span>
            </div>
            <div class="mt-1 tabular-nums">
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
        <div :if={@ai_calls != []} class="overflow-x-auto">
          <table class="table table-sm">
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
                <td class="break-all font-mono">{line.purpose}</td>
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

  defp off_text(:production),
    do: "The code heat map is off on production. It runs on playtest."

  defp off_text(_role),
    do: "The code heat map is off on this app. Set CODE_HEAT_MAP=on to turn it on."

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
