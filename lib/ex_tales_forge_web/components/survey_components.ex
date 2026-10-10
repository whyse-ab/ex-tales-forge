defmodule TalesForgeWeb.SurveyComponents do
  @moduledoc """
  Function components for the founder survey pages (`TalesForgeWeb.AdminLive.SurveyLive.Show`
  and `.Results`): markdown blocks, status banners, the question inputs and
  the result bars. Inputs are pill-style radios/checkboxes that wrap, so the
  same markup works at 390 px and on desktop.
  """

  use TalesForgeWeb, :html

  alias TalesForge.Collab.Markdown
  alias TalesForge.Survey.Question

  @doc "Markdown from the survey file (raw HTML in it is escaped)."
  @spec md(map()) :: Phoenix.LiveView.Rendered.t()
  attr :text, :string, default: nil
  attr :class, :any, default: nil

  def md(assigns) do
    ~H"""
    <div :if={@text} class={["prose prose-sm max-w-[75ch] text-[var(--paper-ink)]", @class]}>
      {Markdown.to_html(@text)}
    </div>
    """
  end

  @doc "Admin error box for definition problems (bad JSON, GitHub down)."
  @spec problems(map()) :: Phoenix.LiveView.Rendered.t()
  attr :problems, :list, required: true
  attr :source, :string, default: nil

  def problems(assigns) do
    ~H"""
    <div
      :if={@problems != []}
      id="survey-problems"
      role="alert"
      class="space-y-2 rounded-lg border border-[var(--paper-danger-rule)] bg-[var(--paper-panel)] p-3 text-sm text-[var(--paper-danger-ink)]"
    >
      <p class="font-semibold">Admin: the survey file in tales-forge-docs has a problem</p>
      <ul class="list-disc space-y-1 pl-5">
        <li :for={problem <- @problems} class="break-words">{problem}</li>
      </ul>
      <p :if={@source} class="text-[var(--paper-muted)]">Reading from: {@source}</p>
    </div>
    """
  end

  @doc "The 'Latest findings' box; a placeholder is shown as such."
  @spec findings(map()) :: Phoenix.LiveView.Rendered.t()
  attr :findings, :map, default: nil

  def findings(assigns) do
    ~H"""
    <section
      :if={@findings}
      id="latest-findings"
      class={[
        "space-y-2 rounded-lg border p-3 sm:p-4",
        @findings.placeholder &&
          "border-dashed border-[var(--paper-warn-ink)] bg-[var(--paper-warn-bg)] text-[var(--paper-warn-ink)]",
        !@findings.placeholder && "border-[var(--paper-rule)] bg-[var(--paper-panel)]"
      ]}
    >
      <h2 class="flex flex-wrap items-center gap-2 font-serif text-lg font-semibold">
        {@findings.title}
        <span
          :if={@findings.placeholder}
          class="rounded-full border border-current px-2 py-0.5 text-xs font-medium"
        >
          Placeholder
        </span>
      </h2>
      <.md text={@findings.markdown} class="text-current" />
    </section>
    """
  end

  @doc "Status banner for draft and closed surveys."
  @spec status_banner(map()) :: Phoenix.LiveView.Rendered.t()
  attr :status, :atom, required: true

  def status_banner(%{status: :open} = assigns), do: ~H""

  def status_banner(assigns) do
    ~H"""
    <p
      id="survey-status"
      class={[
        "rounded-lg px-3 py-2 text-sm",
        @status == :draft && "bg-[var(--paper-info-bg)] text-[var(--paper-info-ink)]",
        @status == :closed && "bg-[var(--paper-quiet-bg)] text-[var(--paper-quiet-ink)]"
      ]}
    >
      <%= if @status == :draft do %>
        <strong>Draft.</strong>
        This survey hasn't been sent yet. Answers saved now are kept and marked as draft answers.
      <% else %>
        <strong>Closed.</strong> Answers can no longer be changed.
      <% end %>
    </p>
    """
  end

  @doc "One question with its inputs, inside a section form."
  @spec question(map()) :: Phoenix.LiveView.Rendered.t()
  attr :q, Question, required: true
  attr :answers, :map, required: true
  attr :base_url, :string, default: nil
  attr :disabled, :boolean, default: false

  def question(assigns) do
    ~H"""
    <fieldset
      id={"q-#{@q.id}"}
      class="min-w-0 space-y-3 border-t border-[var(--paper-rule)] pt-4 first:border-t-0 first:pt-0"
      disabled={@disabled}
    >
      <legend class="contents">
        <h3 class="font-serif text-base font-semibold text-[var(--paper-ink)]">
          <span :if={@q.number != ""} class="text-[var(--paper-muted)]">{@q.number}.</span>
          {strip_bold(@q.title)}
          <span :if={@q.required} class="text-[var(--paper-accent)]" title="required">*</span>
        </h3>
      </legend>
      <.excerpt :if={@q.type == :excerpt} q={@q} base_url={@base_url} />
      <.md :if={@q.text} text={@q.text} />
      <.input_for q={@q} answers={@answers} />
      <.text_field
        :if={@q.type == :checkboxes and @q.other}
        name={"answers[#{@q.id}.other]"}
        label="Other"
        value={@answers[Question.sub_key(@q, "other")]}
      />
      <.text_field
        :for={fu <- @q.follow_ups}
        name={"answers[#{Question.sub_key(@q, fu.id)}]"}
        label={fu.label}
        hint={fu.id == "why" && @q.why_hint}
        value={@answers[Question.sub_key(@q, fu.id)]}
      />
    </fieldset>
    """
  end

  attr :q, Question, required: true
  attr :base_url, :string, required: true

  defp excerpt(assigns) do
    ~H"""
    <div class="space-y-2 text-sm">
      <p class="text-[var(--paper-muted)]">
        <a
          href={Question.turn_url(@q, @base_url)}
          target="_blank"
          rel="noopener"
          class="font-medium text-[var(--paper-accent)] underline"
        >
          Turn {@q.turn} of this run
        </a>
        · {@q.character} <.md :if={@q.context} text={@q.context} class="inline [&_p]:inline" />
      </p>
      <p class="inline-flex flex-wrap items-baseline gap-x-2 rounded bg-[var(--paper-bg)] px-2 py-1">
        <span class="play-label text-[var(--paper-muted)]">Jev</span>
        <span class="font-serif text-lg font-bold text-[var(--paper-ink)]">
          {:erlang.float_to_binary(@q.jev_score, decimals: 2)} of 5
        </span>
        <span :if={@q.jev_scale == "stricter"} class="text-xs text-[var(--paper-muted)]">
          stricter scale
        </span>
      </p>
      <blockquote class="space-y-2 border-l-4 border-[var(--paper-rule)] pl-3 text-[var(--paper-ink)]">
        <p><span class="play-label text-[var(--paper-muted)]">Player</span> {@q.player}</p>
        <p><span class="play-label text-[var(--paper-muted)]">Game</span> {@q.game}</p>
      </blockquote>
    </div>
    """
  end

  attr :q, Question, required: true
  attr :answers, :map, required: true

  defp input_for(%{q: %Question{type: type}} = assigns) when type in [:single, :excerpt] do
    ~H"""
    <div class="flex flex-wrap gap-2">
      <.pill
        :for={opt <- @q.options}
        type="radio"
        name={"answers[#{@q.id}]"}
        value={opt}
        label={opt}
        checked={@answers[@q.id] == opt}
      />
    </div>
    """
  end

  defp input_for(%{q: %Question{type: :checkboxes}} = assigns) do
    ~H"""
    <div class="flex flex-wrap gap-2">
      <input type="hidden" name={"answers[#{@q.id}][]"} value="" />
      <.pill
        :for={opt <- @q.options}
        type="checkbox"
        name={"answers[#{@q.id}][]"}
        value={opt}
        label={opt}
        checked={opt in List.wrap(@answers[@q.id])}
      />
    </div>
    """
  end

  defp input_for(%{q: %Question{type: :scale}} = assigns) do
    ~H"""
    <div class="space-y-1">
      <div class="flex flex-wrap gap-2">
        <.pill
          :for={n <- @q.min..@q.max}
          type="radio"
          name={"answers[#{@q.id}]"}
          value={Integer.to_string(n)}
          label={Integer.to_string(n)}
          checked={@answers[@q.id] == n}
          square
        />
      </div>
      <p class="text-xs text-[var(--paper-muted)]">
        {@q.min} = {@q.min_label} · {@q.max} = {@q.max_label}
      </p>
    </div>
    """
  end

  defp input_for(%{q: %Question{type: :grid}} = assigns) do
    assigns = assign(assigns, :cells, assigns.answers[assigns.q.id] || %{})

    ~H"""
    <div class="space-y-3">
      <p :if={@q.numeric} class="text-xs text-[var(--paper-muted)]">
        {List.first(@q.columns)} · {List.last(@q.columns)}
      </p>
      <div
        :for={{row, i} <- Enum.with_index(@q.rows)}
        class="grid gap-1.5 sm:grid-cols-[minmax(10rem,14rem)_minmax(0,1fr)] sm:items-center"
      >
        <p class="text-sm text-[var(--paper-ink)]">{row}</p>
        <div class="flex flex-wrap gap-1.5">
          <input :if={@q.multi} type="hidden" name={"answers[#{@q.id}][#{i}][]"} value="" />
          <.pill
            :for={col <- @q.columns}
            type={if @q.multi, do: "checkbox", else: "radio"}
            name={if @q.multi, do: "answers[#{@q.id}][#{i}][]", else: "answers[#{@q.id}][#{i}]"}
            value={col}
            label={if @q.numeric, do: short_column(col), else: col}
            title={col}
            checked={col in List.wrap(@cells[row])}
            square={@q.numeric}
          />
        </div>
      </div>
    </div>
    """
  end

  defp input_for(%{q: %Question{type: :text}} = assigns) do
    ~H"""
    <textarea
      name={"answers[#{@q.id}]"}
      rows={if @q.long, do: 5, else: 2}
      phx-debounce="800"
      class="w-full rounded border border-[var(--paper-rule)] bg-[var(--paper-bg)] p-2 text-sm text-[var(--paper-ink)]"
    >{@answers[@q.id]}</textarea>
    """
  end

  attr :type, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :checked, :boolean, default: false
  attr :square, :boolean, default: false
  attr :title, :string, default: nil

  defp pill(assigns) do
    ~H"""
    <label class="relative cursor-pointer" title={@title}>
      <input
        type={@type}
        name={@name}
        value={@value}
        checked={@checked}
        class="peer absolute inset-0 h-full w-full cursor-pointer opacity-0"
      />
      <span class={[
        "inline-flex min-h-9 items-center justify-center rounded-full border px-3 py-1 text-sm",
        "border-[var(--paper-rule)] bg-[var(--paper-bg)] text-[var(--paper-ink)]",
        "peer-checked:border-[var(--paper-accent)] peer-checked:bg-[var(--paper-accent)] peer-checked:text-[var(--paper-on-accent)]",
        "peer-focus-visible:ring-2 peer-focus-visible:ring-[var(--paper-accent)] peer-disabled:opacity-60",
        @square && "min-w-9 px-2"
      ]}>
        {@label}
      </span>
    </label>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, default: nil
  attr :hint, :any, default: nil

  defp text_field(assigns) do
    ~H"""
    <label class="block space-y-1">
      <span class="text-xs text-[var(--paper-muted)]">
        {strip_bold(String.replace(@label, "*", ""))} <span :if={@hint}>· {@hint}</span>
        <span class="opacity-70">(optional)</span>
      </span>
      <input
        type="text"
        name={@name}
        value={@value}
        phx-debounce="800"
        class="w-full rounded border border-[var(--paper-rule)] bg-[var(--paper-bg)] px-2 py-1.5 text-sm text-[var(--paper-ink)]"
      />
    </label>
    """
  end

  @doc """
  The founder tabs on the survey page: one link per active survey with the
  signed-in founder's status. `current` is the open survey's id. Renders
  nothing when there are no tabs.
  """
  @spec survey_tabs(map()) :: Phoenix.LiveView.Rendered.t()
  attr :tabs, :list, required: true, doc: "`%{id, title, status}` per active survey"
  attr :current, :string, default: nil

  def survey_tabs(assigns) do
    ~H"""
    <nav
      :if={@tabs != []}
      id="survey-tabs"
      aria-label="Open surveys"
      class="flex flex-wrap gap-2 border-b border-[var(--paper-rule)] pb-2"
    >
      <.link
        :for={tab <- @tabs}
        id={"survey-tab-#{tab.id}"}
        navigate={~p"/admin/founders/surveys/#{tab.id}"}
        aria-current={if tab.id == @current, do: "page", else: "false"}
        class={[
          "rounded-t border px-3 py-2 text-sm",
          if(tab.id == @current,
            do: "border-[var(--paper-accent)] bg-[var(--paper-panel)] text-[var(--paper-ink)]",
            else: "border-transparent text-[var(--paper-muted)] hover:border-[var(--paper-rule)]"
          )
        ]}
      >
        <span class="font-medium">{tab.title}</span>
        <span
          class={["ml-1 rounded px-1.5 py-0.5 text-xs", status_class(tab.status)]}
          data-status={tab.status}
        >
          {TalesForge.Surveys.status_label(tab.status)}
        </span>
      </.link>
    </nav>
    """
  end

  @doc """
  CSS classes for a founder status badge.

      iex> TalesForgeWeb.SurveyComponents.status_class(:done)
      "bg-[var(--paper-accent)] text-[var(--paper-on-accent)]"
  """
  @spec status_class(TalesForge.Surveys.founder_status()) :: String.t()
  def status_class(:done), do: "bg-[var(--paper-accent)] text-[var(--paper-on-accent)]"

  def status_class(:in_progress),
    do: "border border-[var(--paper-accent)] text-[var(--paper-ink)]"

  def status_class(:not_started), do: "bg-[var(--paper-bg)] text-[var(--paper-muted)]"

  @doc "A horizontal count bar for the results page."
  @spec bar(map()) :: Phoenix.LiveView.Rendered.t()
  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :total, :integer, required: true
  attr :earlier, :boolean, default: false
  attr :labels, :string, default: nil, doc: "the option's structured labels as text"

  def bar(assigns) do
    assigns =
      assign(
        assigns,
        :pct,
        if(assigns.total > 0, do: round(100 * assigns.count / assigns.total), else: 0)
      )

    ~H"""
    <div class="grid grid-cols-[minmax(0,1fr)_2.5rem] items-center gap-2 text-sm">
      <div class="min-w-0">
        <p class="truncate text-[var(--paper-ink)]" title={@label}>
          {@label}<span :if={@earlier} class="text-[var(--paper-muted)]"> (earlier wording)</span>
        </p>
        <p :if={@labels} class="truncate font-mono text-xs text-[var(--paper-muted)]" title={@labels}>
          {@labels}
        </p>
        <div class="h-1.5 rounded bg-[var(--paper-bg)]">
          <div class="h-1.5 rounded bg-[var(--paper-accent)]" style={"width: #{@pct}%"}></div>
        </div>
      </div>
      <p class="text-right tabular-nums text-[var(--paper-ink)]">{@count}</p>
    </div>
    """
  end

  @doc """
  The short label of a numeric grid column: its leading number.

      iex> TalesForgeWeb.SurveyComponents.short_column("5 Would love to play")
      "5"
  """
  @spec short_column(String.t()) :: String.t()
  def short_column(column) do
    case Regex.run(~r/\A(\d+)/, column) do
      [_, n] -> n
      nil -> column
    end
  end

  @doc """
  Drops markdown bold markers from a title.

      iex> TalesForgeWeb.SurveyComponents.strip_bold("As **Paul**")
      "As Paul"
  """
  @spec strip_bold(String.t()) :: String.t()
  def strip_bold(text), do: String.replace(text, "**", "")
end
