defmodule TalesForgeWeb.SurveyExportController do
  @moduledoc """
  Survey result downloads for team members: `results.csv` (one row per user,
  one column per question or sub-item; `TalesForge.Survey.Results.to_csv/2`)
  and `results.md` (the per-persona Markdown summary).
  """

  use TalesForgeWeb, :controller

  alias TalesForge.Survey.Results
  alias TalesForge.Survey.Source
  alias TalesForge.Surveys
  alias TalesForgeWeb.TimeAgo

  @doc "GET /admin/founders/surveys/:id/results.csv"
  @spec csv(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def csv(conn, %{"id" => id}) do
    with_definition(conn, id, fn definition, responses ->
      send_download(conn, {:binary, Results.to_csv(definition, responses)},
        filename: "#{id}-results.csv",
        content_type: "text/csv"
      )
    end)
  end

  @doc "GET /admin/founders/surveys/:id/results.md"
  @spec markdown(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def markdown(conn, %{"id" => id}) do
    with_definition(conn, id, fn definition, responses ->
      text = Results.to_markdown(definition, responses, TimeAgo.stockholm(DateTime.utc_now()))

      send_download(conn, {:binary, text},
        filename: "#{id}-results.md",
        content_type: "text/markdown"
      )
    end)
  end

  defp with_definition(conn, id, fun) do
    case Source.load(id) do
      {:ok, %{definition: definition}} ->
        fun.(definition, Surveys.list_responses(definition.id))

      {:error, problems} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(404, "Survey not available: " <> Enum.join(problems, "; "))
    end
  end
end
