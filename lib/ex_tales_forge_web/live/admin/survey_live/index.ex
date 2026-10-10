defmodule TalesForgeWeb.AdminLive.SurveyLive.Index do
  @moduledoc """
  Every founder survey in one table (`/admin/founders/surveys`): each survey file the
  docs hold (`TalesForge.Surveys.overview/1`), whether it is an open tab or
  closed, how many founders answered, and each founder's status (not
  started, in progress, done). Closed and inactive surveys stay listed, with
  links to their results, CSV and Markdown exports.
  """

  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents, only: [section_card: 1]
  import TalesForgeWeb.SurveyComponents, only: [problems: 1, status_class: 1]

  alias TalesForge.Survey.Definition
  alias TalesForge.Surveys

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Founder surveys") |> load([])}
  end

  @impl true
  def handle_event("reload", _params, socket), do: {:noreply, load(socket, fresh: true)}

  defp load(socket, opts) do
    overview = Surveys.overview(opts)

    socket
    |> assign(:surveys, overview.surveys)
    |> assign(:logins, overview.logins)
    |> assign(:problems, overview.problems)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.admin socket={@socket} flash={@flash} active="survey">
      <header class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0 space-y-1">
          <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">Founder surveys</h2>
          <p class="text-sm text-[var(--paper-muted)]">
            Every survey file in tales-forge-docs. Open tabs show on <.link
              navigate={~p"/admin/founders/survey"}
              class="text-[var(--paper-accent)] underline"
            >
              the survey page
            </.link>; set <code>"active"</code>
            in a survey's JSON to add or remove its tab.
          </p>
        </div>
        <button type="button" phx-click="reload" class={button_class()}>Sync from repo</button>
      </header>

      <.problems problems={@problems} />

      <.section_card title="Status per founder" id="surveys-overview">
        <p :if={@surveys == []} class="text-sm text-[var(--paper-muted)]">No survey files found.</p>
        <div :if={@surveys != []} class="overflow-x-auto">
          <table class="w-full text-left text-sm">
            <thead class="text-[var(--paper-muted)]">
              <tr>
                <th class="py-1 pr-2 font-medium">Survey</th>
                <th class="py-1 pr-2 font-medium">State</th>
                <th class="py-1 pr-2 font-medium">Answered</th>
                <th :for={login <- @logins} class="py-1 pr-2 font-medium">@{login}</th>
                <th class="py-1 font-medium">Results</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={row <- @surveys}
                id={"survey-row-#{row.id}"}
                class="border-t border-[var(--paper-rule)] align-top"
              >
                <td class="py-1.5 pr-2">
                  <.link
                    navigate={~p"/admin/founders/surveys/#{row.id}"}
                    class="text-[var(--paper-accent)] underline"
                  >
                    {if row.definition, do: row.definition.title, else: row.id}
                  </.link>
                </td>
                <td class="py-1.5 pr-2 text-[var(--paper-muted)]">{state(row.definition)}</td>
                <td class="py-1.5 pr-2 tabular-nums">{row.responses}</td>
                <td :for={status <- statuses(row, @logins)} class="py-1.5 pr-2">
                  <span
                    class={["rounded px-1.5 py-0.5 text-xs", status_class(status)]}
                    data-status={status}
                  >
                    {Surveys.status_label(status)}
                  </span>
                </td>
                <td class="py-1.5 whitespace-nowrap">
                  <.link
                    :if={row.definition}
                    navigate={~p"/admin/founders/surveys/#{row.id}/results"}
                    class="text-[var(--paper-accent)] underline"
                  >
                    Results
                  </.link>
                  <a
                    :if={row.definition}
                    href={~p"/admin/founders/surveys/#{row.id}/results.csv"}
                    class="ml-2 text-[var(--paper-accent)] underline"
                  >
                    CSV
                  </a>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </.section_card>
    </Layouts.admin>
    """
  end

  @doc """
  The state column: an open tab, inactive (answerable but not a tab), or
  closed; "failed to load" when the file is broken.

      iex> TalesForgeWeb.AdminLive.SurveyLive.Index.state(%TalesForge.Survey.Definition{active: true, status: :open})
      "Open tab"
      iex> TalesForgeWeb.AdminLive.SurveyLive.Index.state(%TalesForge.Survey.Definition{active: true, status: :closed})
      "Closed"
  """
  @spec state(Definition.t() | nil) :: String.t()
  def state(nil), do: "Failed to load"
  def state(%Definition{status: :closed}), do: "Closed"

  def state(%Definition{} = definition),
    do: if(Definition.active?(definition), do: "Open tab", else: "Not a tab")

  defp statuses(row, logins), do: Enum.map(logins, &Map.get(row.statuses, &1, :not_started))

  defp button_class,
    do:
      "rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-3 py-2 text-sm text-[var(--paper-ink)] hover:border-[var(--paper-accent)]"
end
