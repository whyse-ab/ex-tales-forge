defmodule TalesForgeWeb.AdminLive.SurveyLive.Show do
  @moduledoc """
  The founder survey page. `/admin/founders/survey` shows one tab per active survey
  (`TalesForge.Surveys.active/1`, from each docs file's `active` flag) with
  the signed-in founder's status on each (not started, in progress, done) and
  opens the first; `/admin/founders/surveys/:id` opens any survey, active or not.
  Questions come from the survey file in
  tales-forge-docs (`TalesForge.Survey.Source`); answers autosave per section
  into the signed-in user's response (`TalesForge.Surveys`), keyed by their
  GitHub login, so there is no name question. Shows who you answer as and the
  save state; read-only once the survey is closed.
  """

  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents, only: [section_card: 1]
  import TalesForgeWeb.SurveyComponents

  alias TalesForge.AdminAuth
  alias TalesForge.Survey.Answers
  alias TalesForge.Survey.Definition
  alias TalesForge.Survey.Source
  alias TalesForge.Surveys
  alias TalesForgeWeb.TimeAgo

  @impl true
  def mount(params, session, socket) do
    login = session[AdminAuth.github_login_key()]
    active = Surveys.active()
    id = params["id"] || first_id(active)

    {:ok,
     socket
     |> assign(:login, login)
     |> assign(:saved_at, nil)
     |> assign(:save_error, nil)
     |> assign(:tabs, tabs(active, login))
     |> assign(:survey_id, id)
     |> load(Source.load(id))}
  end

  @impl true
  def handle_event("save", %{"section" => section_id} = params, socket) do
    answers = Map.get(params, "answers", %{})
    user = %{login: socket.assigns.login, email: socket.assigns.admin_email}

    case Surveys.save_section(socket.assigns.loaded, user, section_id, answers) do
      {:ok, response} ->
        {:noreply,
         socket
         |> assign(:answers, response.answers)
         |> assign(:saved_at, response.updated_at)
         |> assign(:save_error, nil)
         |> update_tab(response)}

      {:error, :closed} ->
        {:noreply, assign(socket, :save_error, "This survey is closed; nothing was saved.")}

      {:error, :wrong_app} ->
        {:noreply,
         assign(socket, :save_error, "Surveys are answered on production; nothing was saved.")}

      {:error, _reason} ->
        {:noreply, assign(socket, :save_error, "Couldn't save. Try again in a moment.")}
    end
  end

  def handle_event("reload", _params, socket) do
    socket = load(socket, Source.load(socket.assigns.survey_id, fresh: true))
    {:noreply, assign(socket, :tabs, tabs(Surveys.active(fresh: true), socket.assigns.login))}
  end

  def handle_event("clear", _params, socket) do
    case Surveys.clear_response(socket.assigns.loaded, socket.assigns.login) do
      :ok ->
        {:noreply,
         socket
         |> assign(answers: %{}, saved_at: nil)
         |> update_tab(nil)
         |> put_flash(:info, "Your answers were cleared.")}

      {:error, :closed} ->
        {:noreply, put_flash(socket, :error, "This survey is closed.")}

      {:error, :wrong_app} ->
        {:noreply, put_flash(socket, :error, "Surveys are answered on production.")}
    end
  end

  # With no active survey (or no docs at all), fall back to the configured one.
  defp first_id([first | _rest]), do: first.definition.id
  defp first_id([]), do: Surveys.current_id()

  defp tabs(active, login) do
    Enum.map(active, fn %{definition: definition} ->
      response = login && Surveys.get_response(definition.id, login)

      %{
        id: definition.id,
        title: Definition.tab_title(definition),
        status: Surveys.founder_status(definition, response)
      }
    end)
  end

  defp update_tab(socket, response) do
    definition = socket.assigns.definition
    status = Surveys.founder_status(definition, response)

    tabs =
      Enum.map(socket.assigns.tabs, fn
        %{id: id} = tab when id == definition.id -> %{tab | status: status}
        tab -> tab
      end)

    assign(socket, :tabs, tabs)
  end

  defp load(socket, {:ok, loaded}) do
    response =
      socket.assigns.login && Surveys.get_response(loaded.definition.id, socket.assigns.login)

    socket
    |> assign(:page_title, loaded.definition.title)
    |> assign(:loaded, loaded)
    |> assign(:definition, loaded.definition)
    |> assign(:problems, loaded.problems)
    |> assign(:answers, (response && response.answers) || %{})
    |> assign(:saved_at, response && response.updated_at)
  end

  defp load(socket, {:error, problems}) do
    socket
    |> assign(:page_title, "Survey")
    |> assign(:loaded, nil)
    |> assign(:definition, nil)
    |> assign(:problems, problems)
    |> assign(:answers, %{})
  end

  @impl true
  def render(%{definition: nil} = assigns) do
    ~H"""
    <Layouts.admin flash={@flash} active="survey">
      <.survey_tabs tabs={@tabs} current={@survey_id} />
      <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">Survey</h2>
      <.problems problems={@problems} source={Source.describe(@survey_id)} />
      <button type="button" phx-click="reload" class={button_class()}>Reload from docs</button>
    </Layouts.admin>
    """
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        progress: Answers.progress(assigns.definition, assigns.answers),
        disabled: not Definition.answerable?(assigns.definition)
      )

    ~H"""
    <Layouts.admin flash={@flash} active="survey" page={@definition.title}>
      <.survey_tabs tabs={@tabs} current={@survey_id} />
      <p
        :if={not Definition.active?(@definition)}
        id="survey-inactive"
        class="rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-3 py-2 text-sm text-[var(--paper-muted)]"
      >
        This survey is not one of the open tabs right now. You can still read it here, and its results stay available.
      </p>
      <header class="space-y-2">
        <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">{@definition.title}</h2>
        <p class="text-sm text-[var(--paper-muted)]">
          About {@definition.estimated_minutes || "?"} minutes · version {@definition.version} ·
          <.link
            navigate={~p"/admin/founders/surveys/#{@definition.id}/results"}
            class="text-[var(--paper-accent)] underline"
          >
            Results
          </.link>
          ·
          <.link navigate={~p"/admin/founders/surveys"} class="text-[var(--paper-accent)] underline">
            All surveys
          </.link>
        </p>
      </header>

      <div
        id="survey-whoami"
        class="sticky top-0 z-10 flex flex-wrap items-center justify-between gap-x-3 gap-y-1 rounded-lg border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-3 py-2 text-sm shadow-sm"
      >
        <p class="min-w-0 truncate text-[var(--paper-ink)]">
          Answering as <strong>@{@login}</strong>
          <span class="hidden text-[var(--paper-muted)] sm:inline">({@admin_email})</span>
        </p>
        <p id="survey-save-state" class="text-[var(--paper-muted)]">
          <%= cond do %>
            <% @save_error -> %>
              <span class="text-[var(--paper-danger-ink)]">{@save_error}</span>
            <% @saved_at -> %>
              Saved {TimeAgo.stockholm(@saved_at, "%H:%M:%S")} · {@progress.answered}/{@progress.total} answered
            <% true -> %>
              Not started · answers save as you go
          <% end %>
        </p>
      </div>

      <.problems problems={@problems} source={@loaded.source} />
      <.status_banner status={@definition.status} />
      <.findings findings={@definition.latest_findings} />

      <.section_card title="Welcome" id="survey-intro">
        <.md text={@definition.intro} />
      </.section_card>

      <.section_card
        :for={section <- @definition.sections}
        title={section.title}
        id={"section-#{section.id}"}
      >
        <.md text={section.markdown} />
        <form
          :if={section.questions != []}
          id={"form-#{section.id}"}
          phx-change="save"
          phx-submit="save"
          class="group space-y-4"
        >
          <input type="hidden" name="section" value={section.id} />
          <.question
            :for={q <- section.questions}
            q={q}
            answers={@answers}
            base_url={@definition.playtest_base_url}
            disabled={@disabled}
          />
          <p
            :if={!@disabled}
            class="text-right text-xs text-[var(--paper-muted)]"
            aria-live="polite"
          >
            <span class="group-[.phx-change-loading]:hidden">
              {if section_saved?(@answers, section), do: "Saved", else: "Saves as you go"}
            </span>
            <span class="hidden group-[.phx-change-loading]:inline">Saving…</span>
          </p>
        </form>
      </.section_card>

      <div class="flex flex-wrap items-center justify-between gap-3 pb-8 text-sm">
        <p class="text-[var(--paper-muted)]">
          {if @progress.complete?,
            do: "All required questions answered. Thank you!",
            else: "#{@progress.required_total - @progress.required_answered} required questions left."} You can come back and change answers until the survey closes.
        </p>
        <button
          :if={!@disabled and @answers != %{}}
          type="button"
          phx-click="clear"
          data-confirm="Delete all your answers to this survey?"
          class={button_class()}
        >
          Clear my answers
        </button>
      </div>
    </Layouts.admin>
    """
  end

  defp section_saved?(answers, section) do
    Enum.any?(section.questions, &Answers.answered?(answers, &1))
  end

  defp button_class,
    do:
      "rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-3 py-2 text-sm text-[var(--paper-ink)] hover:border-[var(--paper-accent)]"
end
