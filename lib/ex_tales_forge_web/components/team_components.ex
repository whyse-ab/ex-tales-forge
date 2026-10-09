defmodule TalesForgeWeb.TeamComponents do
  @moduledoc """
  Building blocks of the founders' presentation (`/team/presentation`,
  `TalesForgeWeb.TeamPresentationLive`): stat tiles, section headings, inline
  term explanations and the charts.

  The charts are plain HTML and CSS (bars are `div`s sized in percent), drawn
  on the server from `TalesForge.TeamPage` data: no chart library, nothing
  fetched, readable at 320 px and themed through the page's CSS variables.
  Bars grow in when their section scrolls into view, only when motion is
  allowed (`assets/js/team_hooks.js`, `prefers-reduced-motion`). Values come
  in already formatted, so a missing one reads "not measured yet".
  """

  use Phoenix.Component

  import TalesForge.TeamPage, only: [number: 1, score: 1, share: 2]

  alias TalesForge.TeamPage

  @doc "A big number with a small label underneath."
  attr :id, :string, default: nil
  attr :value, :string, required: true
  attr :label, :string, required: true
  slot :inner_block

  @spec stat(map()) :: Phoenix.LiveView.Rendered.t()
  def stat(assigns) do
    ~H"""
    <div id={@id} class="team-card team-stat flex flex-col gap-1 p-4">
      <span class={[
        "font-serif font-bold leading-none text-[var(--paper-accent)]",
        missing?(@value) && "text-base italic text-[var(--paper-muted)]",
        !missing?(@value) && "text-3xl sm:text-4xl"
      ]}>
        {@value}
      </span>
      <span class="text-sm font-semibold">{@label}</span>
      <span :if={@inner_block != []} class="text-xs text-[var(--paper-muted)]">
        {render_slot(@inner_block)}
      </span>
    </div>
    """
  end

  @doc "A section heading (with an optional small kicker) and the intro copy."
  attr :id, :string, required: true
  attr :kicker, :string, default: nil
  attr :title, :string, required: true
  slot :inner_block

  @spec section_head(map()) :: Phoenix.LiveView.Rendered.t()
  def section_head(assigns) do
    ~H"""
    <header class="max-w-3xl space-y-2">
      <p :if={@kicker} class="play-label text-[var(--paper-accent)]">{@kicker}</p>
      <h2 id={"#{@id}-title"} class="font-serif text-2xl font-bold sm:text-3xl">{@title}</h2>
      <p
        :if={@inner_block != []}
        class="text-base leading-relaxed text-[var(--paper-muted)] sm:text-lg"
      >
        {render_slot(@inner_block)}
      </p>
    </header>
    """
  end

  @doc "The one-line explanation of a technical term, in muted italics and brackets."
  attr :text, :string, required: true

  @spec explain(map()) :: Phoenix.LiveView.Rendered.t()
  def explain(assigns) do
    ~H"""
    <span class="team-explain">({@text})</span>
    """
  end

  @doc """
  Vertical bars, one per item (`%{label, value, display}`), scaled to the
  largest value. Bars of missing values are empty and read "not measured yet".
  """
  attr :id, :string, required: true
  attr :items, :list, required: true
  attr :label, :string, required: true, doc: "accessible summary"

  @spec column_chart(map()) :: Phoenix.LiveView.Rendered.t()
  def column_chart(assigns) do
    assigns = assign(assigns, :max, max_value(assigns.items, [:value]))

    ~H"""
    <figure id={@id} class="team-chart" role="img" aria-label={@label}>
      <div class="flex h-44 items-end gap-2 sm:gap-3">
        <div
          :for={item <- @items}
          class="flex h-full min-w-0 flex-1 flex-col items-center justify-end gap-1"
        >
          <span class="text-xs font-semibold tabular-nums">{item.display}</span>
          <div
            class="team-bar-v w-full max-w-14 rounded-t bg-[var(--paper-accent)]"
            style={"height: #{share(item.value, @max)}%"}
          />
          <span class="text-[0.7rem] text-[var(--paper-muted)]">{item.label}</span>
        </div>
      </div>
    </figure>
    """
  end

  @doc """
  Paired vertical bars per item (`%{label, a, b}`): `a` in the accent colour,
  `b` in the second colour, with a legend.
  """
  attr :id, :string, required: true
  attr :items, :list, required: true
  attr :legend, :list, required: true, doc: "[label_a, label_b]"
  attr :label, :string, required: true

  @spec paired_chart(map()) :: Phoenix.LiveView.Rendered.t()
  def paired_chart(assigns) do
    assigns = assign(assigns, :max, max_value(assigns.items, [:a, :b]))

    ~H"""
    <figure id={@id} class="team-chart space-y-3" role="img" aria-label={@label}>
      <div class="flex h-48 items-end gap-2 sm:gap-4">
        <div
          :for={item <- @items}
          class="flex h-full min-w-0 flex-1 flex-col items-center justify-end gap-1"
        >
          <div class="flex h-full w-full items-end justify-center gap-0.5">
            <div class="flex h-full w-1/2 max-w-7 flex-col items-center justify-end">
              <span class="text-[0.65rem] font-semibold tabular-nums">{number(item.a)}</span>
              <div
                class="team-bar-v w-full rounded-t bg-[var(--paper-accent)]"
                style={"height: #{share(item.a, @max)}%"}
              />
            </div>
            <div class="flex h-full w-1/2 max-w-7 flex-col items-center justify-end">
              <span class="text-[0.65rem] tabular-nums text-[var(--paper-muted)]">{number(item.b)}</span>
              <div
                class="team-bar-v w-full rounded-t bg-[var(--team-jev)]"
                style={"height: #{share(item.b, @max)}%"}
              />
            </div>
          </div>
          <span class="text-[0.7rem] text-[var(--paper-muted)]">{item.label}</span>
        </div>
      </div>
      <figcaption class="flex flex-wrap gap-4 text-xs">
        <span class="inline-flex items-center gap-1.5">
          <span class="size-3 rounded-sm bg-[var(--paper-accent)]"></span>{Enum.at(@legend, 0)}
        </span>
        <span class="inline-flex items-center gap-1.5">
          <span class="size-3 rounded-sm bg-[var(--team-jev)]"></span>{Enum.at(@legend, 1)}
        </span>
      </figcaption>
    </figure>
    """
  end

  @doc """
  Horizontal bars (`%{label, value, display}`) against `max` (default: the
  largest value). `color` is a CSS colour for the bars.
  """
  attr :id, :string, required: true
  attr :items, :list, required: true
  attr :max, :any, default: nil
  attr :color, :string, default: "var(--paper-accent)"
  attr :label, :string, required: true

  @spec bar_list(map()) :: Phoenix.LiveView.Rendered.t()
  def bar_list(assigns) do
    assigns = assign(assigns, :scale, assigns.max || max_value(assigns.items, [:value]))

    ~H"""
    <figure id={@id} class="team-chart space-y-2.5" role="img" aria-label={@label}>
      <div :for={item <- @items} class="space-y-1">
        <div class="flex items-baseline justify-between gap-3 text-sm">
          <span class="min-w-0">{item.label}</span>
          <span class="shrink-0 font-semibold tabular-nums">{item.display}</span>
        </div>
        <div class="h-2.5 overflow-hidden rounded-full bg-[var(--paper-margin)]">
          <div
            class="team-bar-h h-full rounded-full"
            style={"width: #{share(item.value, @scale)}%; background: #{@color}"}
          />
        </div>
      </div>
    </figure>
    """
  end

  @doc """
  A bullet chart of latency: a bar to the timeout, the median and p95 as
  markers and the slowest read as a faint tick.
  """
  attr :id, :string, required: true
  attr :p50, :any, required: true
  attr :p95, :any, required: true
  attr :max, :any, required: true
  attr :timeout, :any, required: true

  @spec latency_chart(map()) :: Phoenix.LiveView.Rendered.t()
  def latency_chart(assigns) do
    ~H"""
    <figure
      id={@id}
      class="team-chart space-y-2"
      role="img"
      aria-label={"Intent read latency: median #{TeamPage.ms(@p50)}, p95 #{TeamPage.ms(@p95)}, slowest #{TeamPage.ms(@max)}, limit #{TeamPage.ms(@timeout)}"}
    >
      <div class="relative h-10">
        <div class="absolute inset-x-0 top-3 h-4 rounded bg-[var(--paper-margin)]" />
        <div
          class="team-bar-h absolute left-0 top-3 h-4 rounded-l bg-[var(--team-jev)] opacity-35"
          style={"width: #{share(@p95, @timeout)}%"}
        />
        <div
          class="absolute top-1 h-8 w-0.5 bg-[var(--paper-muted)] opacity-50"
          style={"left: #{share(@max, @timeout)}%"}
          title={"slowest: #{TeamPage.ms(@max)}"}
        />
        <div
          class="absolute top-0.5 h-9 w-1 rounded bg-[var(--team-jev)]"
          style={"left: #{share(@p50, @timeout)}%"}
        />
        <div
          class="absolute top-0.5 h-9 w-1 rounded bg-[var(--paper-ink)]"
          style={"left: #{share(@p95, @timeout)}%"}
        />
      </div>
      <div class="flex justify-between text-[0.7rem] text-[var(--paper-muted)]">
        <span>0</span>
        <span>{TeamPage.ms(@timeout)} limit</span>
      </div>
      <figcaption class="flex flex-wrap gap-x-4 gap-y-1 text-xs">
        <span class="inline-flex items-center gap-1.5">
          <span class="h-3 w-1 rounded bg-[var(--team-jev)]"></span> median {TeamPage.ms(@p50)}
        </span>
        <span class="inline-flex items-center gap-1.5">
          <span class="h-3 w-1 rounded bg-[var(--paper-ink)]"></span> p95 {TeamPage.ms(@p95)}
        </span>
        <span class="inline-flex items-center gap-1.5">
          <span class="h-3 w-0.5 bg-[var(--paper-muted)] opacity-50"></span>
          slowest {TeamPage.ms(@max)}
        </span>
      </figcaption>
    </figure>
    """
  end

  @doc """
  One stacked bar of parts (`%{label, value, kind}`; kind `real`, `attack` or
  `tricky`) with a legend listing every part.
  """
  attr :id, :string, required: true
  attr :parts, :list, required: true
  attr :label, :string, required: true

  @spec stacked_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def stacked_bar(assigns) do
    total = assigns.parts |> Enum.map(& &1.value) |> Enum.filter(&is_number/1) |> Enum.sum()
    assigns = assign(assigns, :total, total)

    ~H"""
    <figure id={@id} class="team-chart space-y-3" role="img" aria-label={@label}>
      <div class="flex h-6 overflow-hidden rounded">
        <div
          :for={part <- @parts}
          class={[
            "team-bar-h h-full border-r border-[var(--paper-panel)] last:border-r-0",
            kind_bg(part.kind)
          ]}
          style={"width: #{share(part.value, @total)}%"}
          title={"#{part.label}: #{number(part.value)}"}
        />
      </div>
      <ul class="grid gap-x-4 gap-y-1 text-xs sm:grid-cols-2 lg:grid-cols-3">
        <li :for={part <- @parts} class="flex items-center gap-2">
          <span class={["size-3 shrink-0 rounded-sm", kind_bg(part.kind)]}></span>
          <span class="min-w-0 flex-1">{part.label}</span>
          <span class="font-semibold tabular-nums">{number(part.value)}</span>
        </li>
      </ul>
    </figure>
    """
  end

  defp kind_bg("real"), do: "bg-[var(--team-jev)]"
  defp kind_bg("attack"), do: "bg-[var(--team-seal)]"
  defp kind_bg(_tricky), do: "bg-[var(--team-llm)]"

  @doc """
  Small multiples of persona scores: one panel per persona (`%{id, name,
  style}`), one bar per series (`%{"label", "weighted", "unsure_pct",
  "completed_runs"}`) on a 1-5 scale, and a light band of +-`noise` around
  the first series. Ronny (the anti-persona) is drawn dashed.
  """
  attr :id, :string, required: true
  attr :personas, :list, required: true
  attr :series, :list, required: true
  attr :noise, :float, default: 0.3

  @spec persona_panels(map()) :: Phoenix.LiveView.Rendered.t()
  def persona_panels(assigns) do
    ~H"""
    <figure id={@id} class="team-chart space-y-4" aria-label="Persona scores per series, 1 to 5">
      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
        <div
          :for={persona <- @personas}
          id={"#{@id}-#{persona["id"]}"}
          class={[
            "rounded-lg border border-[var(--paper-rule)] p-3",
            persona["id"] == "ronny" && "team-anti"
          ]}
        >
          <p class="flex items-baseline justify-between gap-2 text-sm font-semibold">
            {persona["name"]}
            <span
              :if={persona["id"] == "ronny"}
              class="text-[0.65rem] font-normal uppercase tracking-wide text-[var(--paper-muted)]"
            >
              anti-persona
            </span>
          </p>
          <div class="relative mt-2 flex h-32 items-end gap-1.5 border-b border-[var(--paper-rule)]">
            <.noise_band value={baseline(@series, persona["id"])} noise={@noise} />
            <div
              :for={{s, i} <- Enum.with_index(@series, 1)}
              class="relative z-10 flex h-full flex-1 flex-col items-center justify-end"
              title={series_tip(s, persona["id"])}
            >
              <span class="text-[0.65rem] font-semibold tabular-nums">{weighted_label(
                s,
                persona["id"]
              )}</span>
              <div
                class={[
                  "team-bar-v w-full rounded-t",
                  persona["id"] == "ronny" &&
                    "border-2 border-dashed border-[var(--paper-muted)] bg-transparent",
                  persona["id"] != "ronny" && "bg-[var(--paper-accent)]"
                ]}
                style={"height: #{scale_1_5(get_in(s, ["weighted", persona["id"]]))}%; opacity: #{0.55 + i * 0.1}"}
              />
            </div>
          </div>
          <div class="mt-1 flex gap-1.5 text-center text-[0.65rem] text-[var(--paper-muted)]">
            <span :for={{_s, i} <- Enum.with_index(@series, 1)} class="flex-1">{i}</span>
          </div>
        </div>
      </div>
      <figcaption class="space-y-1 text-xs text-[var(--paper-muted)]">
        <ol class="grid gap-x-4 gap-y-0.5 sm:grid-cols-2">
          <li :for={{s, i} <- Enum.with_index(@series, 1)}>
            <span class="font-semibold text-[var(--paper-ink)]">{i}.</span>
            {s["label"]} · {number(s["completed_runs"])} runs
          </li>
        </ol>
        <p>
          <span class="mr-1 inline-block h-2.5 w-5 rounded-sm bg-[var(--team-noise)] align-middle"></span>
          ±{number(@noise)} around series 1: noise at this sample size. Scale 1 (frustrated) to 5 (delighted).
        </p>
      </figcaption>
    </figure>
    """
  end

  attr :value, :any, required: true
  attr :noise, :float, required: true

  defp noise_band(%{value: value} = assigns) when is_number(value) do
    assigns =
      assign(assigns,
        bottom: scale_1_5(value - assigns.noise),
        height: scale_1_5(value + assigns.noise) - scale_1_5(value - assigns.noise)
      )

    ~H"""
    <div
      class="absolute inset-x-0 z-0 bg-[var(--team-noise)]"
      style={"bottom: #{@bottom}%; height: #{@height}%"}
    />
    """
  end

  defp noise_band(assigns), do: ~H""

  defp baseline([first | _rest], id), do: get_in(first, ["weighted", id])
  defp baseline([], _id), do: nil

  defp weighted_label(series, id) do
    case get_in(series, ["weighted", id]) do
      value when is_number(value) -> number(value * 1.0)
      _missing -> "–"
    end
  end

  defp series_tip(series, id) do
    "#{series["label"]}: #{score(get_in(series, ["weighted", id]))} · unsure #{TeamPage.pct(get_in(series, ["unsure_pct", id]))} · #{number(series["completed_runs"])} runs"
  end

  # Height in percent of a 1-5 score on a 1-5 axis.
  defp scale_1_5(value) when is_number(value), do: share(value - 1, 4)
  defp scale_1_5(_value), do: 0.0

  @doc """
  A heat strip: one cell per day (`%{"date", "count"}`), darker for more.
  """
  attr :id, :string, required: true
  attr :days, :list, required: true
  attr :label, :string, required: true

  @spec heat_strip(map()) :: Phoenix.LiveView.Rendered.t()
  def heat_strip(assigns) do
    assigns = assign(assigns, :max, assigns.days |> Enum.map(& &1["count"]) |> max_of())

    ~H"""
    <figure id={@id} class="team-chart space-y-1" role="img" aria-label={@label}>
      <div class="flex gap-1">
        <div
          :for={day <- @days}
          class="h-8 min-w-0 flex-1 rounded-sm bg-[var(--paper-accent)]"
          style={"opacity: #{0.12 + share(day["count"], @max) / 100 * 0.88}"}
          title={"#{TeamPage.short_date(day["date"])}: #{number(day["count"])} commits"}
        />
      </div>
      <div class="flex justify-between text-[0.7rem] text-[var(--paper-muted)]">
        <span>{TeamPage.short_date(List.first(@days)["date"])}</span>
        <span>{TeamPage.short_date(List.last(@days)["date"])}</span>
      </div>
    </figure>
    """
  end

  defp max_value(items, keys),
    do: items |> Enum.flat_map(fn item -> Enum.map(keys, &Map.get(item, &1)) end) |> max_of()

  defp max_of(values) do
    case Enum.filter(values, &is_number/1) do
      [] -> 0
      numbers -> Enum.max(numbers)
    end
  end

  defp missing?(value), do: value == TeamPage.not_measured()
end
