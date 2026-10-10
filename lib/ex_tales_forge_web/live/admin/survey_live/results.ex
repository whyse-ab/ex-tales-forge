defmodule TalesForgeWeb.AdminLive.SurveyLive.Results do
  @moduledoc """
  Admin results for a survey (`/admin/surveys/:id/results`): completion, one
  line per user (click a login for their answers), aggregates per question
  grouped by section, so each persona has its own block, and the CSV and
  Markdown exports (`TalesForgeWeb.SurveyExportController`).
  """

  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents, only: [section_card: 1, stat_card: 1]
  import TalesForgeWeb.SurveyComponents

  alias TalesForge.Survey.Results
  alias TalesForge.Survey.Source
  alias TalesForge.Surveys
  alias TalesForgeWeb.TimeAgo

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {:ok, socket |> assign(:survey_id, id) |> assign(:user, nil) |> load(Source.load(id))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :user, params["user"])}
  end

  @impl true
  def handle_event("reload", _params, socket) do
    {:noreply, load(socket, Source.load(socket.assigns.survey_id, fresh: true))}
  end

  defp load(socket, {:ok, loaded}) do
    responses = Surveys.list_responses(loaded.definition.id)
    definition = loaded.definition

    socket
    |> assign(:page_title, "Results: #{definition.title}")
    |> assign(:loaded, loaded)
    |> assign(:definition, definition)
    |> assign(:problems, loaded.problems)
    |> assign(:responses, responses)
    |> assign(:overview, Results.overview(definition, responses))
    |> assign(
      :aggregates,
      Map.new(Results.aggregate(definition, responses), &{&1.question.id, &1})
    )
    |> assign(
      :markdown,
      Results.to_markdown(definition, responses, TimeAgo.stockholm(DateTime.utc_now()))
    )
    |> assign(:snapshots, Surveys.list_snapshots(definition.id))
  end

  defp load(socket, {:error, problems}) do
    socket
    |> assign(:page_title, "Survey results")
    |> assign(:definition, nil)
    |> assign(:problems, problems)
  end

  @impl true
  def render(%{definition: nil} = assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active="survey">
      <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">Survey results</h2>
      <.problems problems={@problems} source={Source.describe(@survey_id)} />
      <button type="button" phx-click="reload" class={button_class()}>Reload from docs</button>
    </Layouts.admin>
    """
  end

  def render(assigns) do
    assigns =
      assign(assigns, :selected, Enum.find(assigns.responses, &(&1.github_login == assigns.user)))

    ~H"""
    <Layouts.admin flash={@flash} active="survey">
      <header class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0 space-y-1">
          <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">Survey results</h2>
          <p class="text-sm text-[var(--paper-muted)]">
            {@definition.title} ·
            <.link
              navigate={survey_path(@definition.id)}
              class="text-[var(--paper-accent)] underline"
            >
              Survey page
            </.link>
            ·
            <.link navigate={~p"/admin/surveys"} class="text-[var(--paper-accent)] underline">
              All surveys
            </.link>
            · {if TalesForge.Survey.Definition.active?(@definition),
              do: "an open tab",
              else: "not an open tab"}
          </p>
        </div>
        <div class="flex flex-wrap gap-2">
          <a href={~p"/admin/surveys/#{@definition.id}/results.csv"} class={button_class()}>CSV</a>
          <a href={~p"/admin/surveys/#{@definition.id}/results.md"} class={button_class()}>
            Markdown summary
          </a>
          <button type="button" phx-click="reload" class={button_class()}>Reload from docs</button>
        </div>
      </header>

      <.problems problems={@problems} source={@loaded.source} />

      <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <.stat_card label="Responses" value={@overview.respondents} />
        <.stat_card label="Complete" value={@overview.complete} />
        <.stat_card label="Version" value={@definition.version} />
        <.stat_card label="Status" value={@definition.status} />
      </div>
      <p class="text-xs text-[var(--paper-muted)]">
        Definition from {@loaded.source}, sha256 {String.slice(@loaded.sha256, 0, 12)}.
        Answers saved under {length(@snapshots)} distinct survey {if length(@snapshots) == 1,
          do: "file",
          else: "files"}.
      </p>

      <.section_card title="Who answered" id="results-users">
        <p :if={@overview.users == []} class="text-sm text-[var(--paper-muted)]">No answers yet.</p>
        <div :if={@overview.users != []} class="overflow-x-auto">
          <table class="w-full text-left text-sm">
            <thead class="text-[var(--paper-muted)]">
              <tr>
                <th class="py-1 pr-2 font-medium">Founder</th>
                <th class="py-1 pr-2 font-medium">Answered</th>
                <th class="py-1 pr-2 font-medium">Complete</th>
                <th class="hidden py-1 pr-2 font-medium sm:table-cell">Last saved</th>
                <th class="hidden py-1 font-medium sm:table-cell">Version</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={u <- @overview.users} class="border-t border-[var(--paper-rule)]">
                <td class="py-1.5 pr-2">
                  <.link
                    patch={~p"/admin/founders/surveys/#{@definition.id}/results?user=#{u.login}"}
                    class="text-[var(--paper-accent)] underline"
                  >
                    @{u.login}
                  </.link>
                </td>
                <td class="py-1.5 pr-2 tabular-nums">{u.progress.answered}/{u.progress.total}</td>
                <td class="py-1.5 pr-2">{if u.progress.complete?, do: "yes", else: "no"}</td>
                <td class="hidden py-1.5 pr-2 sm:table-cell">
                  {u.updated_at && TimeAgo.stockholm(u.updated_at)}
                </td>
                <td class="hidden py-1.5 sm:table-cell">
                  v{u.survey_version}{if u.saved_in_draft, do: " · draft answers"}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.section_card>

      <.section_card
        :if={@selected}
        title={"Answers from @#{@selected.github_login}"}
        id="results-user"
      >
        <dl class="space-y-2 text-sm">
          <div
            :for={q <- TalesForge.Survey.Definition.questions(@definition)}
            class="grid gap-0.5 sm:grid-cols-[14rem_minmax(0,1fr)] sm:gap-3"
          >
            <dt class="text-[var(--paper-muted)]">{q.number} {strip_bold(q.title)}</dt>
            <dd class="min-w-0 break-words text-[var(--paper-ink)]">
              {blank(Results.answer_text(q, @selected.answers))}
              <span
                :for={key <- TalesForge.Survey.Answers.sub_keys(q)}
                :if={@selected.answers[key]}
                class="block text-[var(--paper-muted)]"
              >
                {key |> String.split(".", parts: 2) |> List.last()}: {@selected.answers[key]}
              </span>
            </dd>
          </div>
        </dl>
      </.section_card>

      <nav aria-label="Result sections" class="flex flex-wrap gap-2 text-sm">
        <a
          :for={s <- @definition.sections}
          :if={s.questions != []}
          href={"#results-#{s.id}"}
          class="rounded-full border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-3 py-1 text-[var(--paper-ink)] hover:border-[var(--paper-accent)]"
        >
          {s.title}
        </a>
      </nav>

      <.section_card
        :for={s <- @definition.sections}
        :if={s.questions != []}
        title={s.title}
        id={"results-#{s.id}"}
      >
        <.question_result
          :for={q <- s.questions}
          agg={@aggregates[q.id]}
          base_url={@definition.playtest_base_url}
        />
      </.section_card>

      <.section_card title="Markdown summary (for personas.md)" id="results-markdown">
        <p class="text-sm text-[var(--paper-muted)]">
          The same text as the Markdown download: per persona, key-word votes, own words,
          "does not mean" answers, excerpt ratings and archetype means.
        </p>
        <textarea
          readonly
          rows="14"
          class="w-full rounded border border-[var(--paper-rule)] bg-[var(--paper-bg)] p-2 font-mono text-xs text-[var(--paper-ink)]"
        >{@markdown}</textarea>
      </.section_card>
    </Layouts.admin>
    """
  end

  attr :agg, :map, required: true
  attr :base_url, :string, default: nil

  defp question_result(assigns) do
    ~H"""
    <article
      id={"result-#{@agg.question.id}"}
      class="min-w-0 space-y-2 border-t border-[var(--paper-rule)] pt-3 first:border-t-0 first:pt-0"
    >
      <h3 class="font-serif text-base font-semibold text-[var(--paper-ink)]">
        <span class="text-[var(--paper-muted)]">{@agg.question.number}.</span>
        {strip_bold(@agg.question.title)}
        <span class="text-sm font-normal text-[var(--paper-muted)]">
          · {@agg.answered} answered{if @agg.mean, do: " · mean #{@agg.mean}"}
        </span>
      </h3>
      <p :if={@agg.question.type == :excerpt} class="text-xs text-[var(--paper-muted)]">
        <a
          href={TalesForge.Survey.Question.turn_url(@agg.question, @base_url)}
          target="_blank"
          rel="noopener"
          class="underline"
        >
          Turn {@agg.question.turn}
        </a>
        · Jev {:erlang.float_to_binary(@agg.question.jev_score, decimals: 2)} ({@agg.question.jev_scale} scale)
      </p>
      <div :if={@agg.counts != []} class="space-y-1.5">
        <.bar
          :for={c <- @agg.counts}
          label={c.label}
          count={c.count}
          total={max(@agg.answered, 1)}
          earlier={c.earlier?}
          labels={c.labels}
        />
      </div>
      <div :if={@agg.rows != []} class="overflow-x-auto">
        <table class="w-full text-left text-sm">
          <thead class="text-[var(--paper-muted)]">
            <tr>
              <th class="py-1 pr-2 font-medium">Row</th>
              <th :if={@agg.question.numeric} class="py-1 pr-2 font-medium">Mean</th>
              <th
                :for={col <- @agg.question.columns}
                class="py-1 pr-2 text-right font-medium"
                title={col}
              >
                {if @agg.question.numeric, do: short_column(col), else: col}
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={r <- sorted_rows(@agg)} class="border-t border-[var(--paper-rule)]">
              <td class="py-1 pr-2 text-[var(--paper-ink)]">{r.row}</td>
              <td :if={@agg.question.numeric} class="py-1 pr-2 font-semibold tabular-nums">
                {r.mean || "–"}
              </td>
              <td
                :for={c <- Enum.reject(r.counts, & &1.earlier?)}
                class="py-1 pr-2 text-right tabular-nums text-[var(--paper-muted)]"
              >
                {c.count}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <.quotes :if={@agg.texts != []} title="Answers" entries={@agg.texts} />
      <.quotes :if={@agg.other != []} title="Other" entries={@agg.other} />
      <.quotes
        :for={fu <- @agg.follow_ups}
        :if={fu.entries != []}
        title={strip_bold(String.replace(fu.follow_up.label, "*", ""))}
        entries={fu.entries}
      />
    </article>
    """
  end

  attr :title, :string, required: true
  attr :entries, :list, required: true

  defp quotes(assigns) do
    ~H"""
    <div class="text-sm">
      <p class="text-xs text-[var(--paper-muted)]">{@title}</p>
      <ul class="space-y-1">
        <li :for={e <- @entries} class="break-words text-[var(--paper-ink)]">
          “{e.text}” <span class="text-[var(--paper-muted)]">@{e.login}</span>
        </li>
      </ul>
    </div>
    """
  end

  defp sorted_rows(%{question: %{numeric: true}, rows: rows}),
    do: Enum.sort_by(rows, &{-(&1.mean || 0), &1.row})

  defp sorted_rows(%{rows: rows}), do: rows

  defp survey_path(id), do: ~p"/admin/surveys/#{id}"

  defp blank(""), do: "–"
  defp blank(text), do: text

  defp button_class,
    do:
      "rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-3 py-2 text-sm text-[var(--paper-ink)] hover:border-[var(--paper-accent)]"
end
