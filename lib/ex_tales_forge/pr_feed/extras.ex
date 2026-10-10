defmodule TalesForge.PrFeed.Extras do
  @moduledoc """
  The presentation's GitHub-sourced numbers besides the PR pace
  (`TalesForge.PrFeed.Pace`), refreshed by the PR feed's poller
  (`TalesForge.PrFeed.Poller`) at most every `@refresh_ms` (10 min):

  - **Tests** (`:tests`): the test count, failures and coverage of the
    latest successful CI run on main, read from its "Test" job log
    (`GITHUB_FEED_TOKEN`, which has Actions: read). Fetched again only when a
    newer run appears.
  - **Decisions** (`:decisions`): the `## YYYY-MM-DD` entries of
    tales-forge-docs `docs/decisions.md` on GitHub (`GITHUB_DOCS_TOKEN`, the
    token the docs sync already uses), total and per Stockholm day. Sent with
    the last ETag, so an unchanged file costs no rate limit.

  A group that can't be fetched keeps its last value, or stays nil, and the
  page falls back to `data.json` for that group only. `current/0` reads the
  latest from the poller's ETS table, without a call to the poller.
  """

  require Logger

  alias TalesForge.PrFeed

  @api "https://api.github.com"
  @docs_repo "whyse-ab/tales-forge-docs"
  @decisions_path "docs/decisions.md"
  @refresh_ms 600_000
  @timeout_ms 10_000
  @table TalesForge.PrFeed.Poller

  @typedoc "Test numbers from one CI run on main."
  @type tests :: %{
          tests: non_neg_integer(),
          doctests: non_neg_integer(),
          failures: non_neg_integer(),
          coverage_pct: float() | nil,
          run_id: integer(),
          sha: String.t(),
          at: String.t() | nil
        }

  @typedoc "The decision log's entries."
  @type decisions :: %{
          total: non_neg_integer(),
          by_date: [%{required(String.t()) => String.t() | non_neg_integer()}],
          etag: String.t() | nil,
          fetched_at: DateTime.t()
        }

  @typedoc "What the poller keeps between refreshes."
  @type t :: %{
          tests: tests() | nil,
          decisions: decisions() | nil,
          refreshed_at: DateTime.t() | nil
        }

  @doc "Nothing fetched yet."
  @spec empty() :: t()
  def empty, do: %{tests: nil, decisions: nil, refreshed_at: nil}

  @doc "The latest extras (empty before the first refresh or without a poller)."
  @spec current() :: t()
  def current do
    case :ets.lookup(@table, :extras) do
      [{:extras, extras}] -> extras
      [] -> empty()
    end
  rescue
    ArgumentError -> empty()
  end

  @doc "Stores `extras` as the latest (the poller calls this)."
  @spec store(t()) :: :ok
  def store(extras) do
    :ets.insert(@table, {:extras, extras})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Refreshes `prev` at `now` when it is older than 10 minutes (or never
  refreshed); otherwise returns it unchanged.
  """
  @spec refresh(t(), DateTime.t()) :: t()
  def refresh(prev, %DateTime{} = now) do
    if due?(prev, now) do
      %{
        tests: refresh_tests(prev.tests),
        decisions: refresh_decisions(prev.decisions, now),
        refreshed_at: now
      }
    else
      prev
    end
  end

  @doc """
  True when `extras` should be refreshed at `now`.

      iex> TalesForge.PrFeed.Extras.due?(%{refreshed_at: nil}, ~U[2026-10-10 03:00:00Z])
      true
      iex> TalesForge.PrFeed.Extras.due?(%{refreshed_at: ~U[2026-10-10 02:55:00Z]}, ~U[2026-10-10 03:00:00Z])
      false
  """
  @spec due?(map(), DateTime.t()) :: boolean()
  def due?(%{refreshed_at: nil}, _now), do: true
  def due?(%{refreshed_at: at}, now), do: DateTime.diff(now, at, :millisecond) >= @refresh_ms

  # ── Tests from CI ────────────────────────────────────────────────────────

  defp refresh_tests(prev) do
    with {:ok, token} <- token(PrFeed.token()),
         {:ok, %{"workflow_runs" => [run | _]}} <-
           get(token, "/repos/#{PrFeed.repo()}/actions/workflows/ci.yml/runs",
             branch: "main",
             status: "success",
             per_page: 1
           ) do
      if prev && prev.run_id == run["id"], do: prev, else: tests_of_run(token, run) || prev
    else
      _no_run -> prev
    end
  end

  defp tests_of_run(token, run) do
    with {:ok, %{"jobs" => jobs}} <-
           get(token, "/repos/#{PrFeed.repo()}/actions/runs/#{run["id"]}/jobs", per_page: 50),
         %{"id" => job_id} <- Enum.find(jobs, &(&1["name"] == "Test")),
         {:ok, log} when is_binary(log) <-
           get(token, "/repos/#{PrFeed.repo()}/actions/jobs/#{job_id}/logs", []),
         %{} = counts <- parse_test_log(log) do
      Map.merge(counts, %{run_id: run["id"], sha: run["head_sha"], at: run["updated_at"]})
    else
      other ->
        Logger.info(
          "PR feed extras: no test counts from CI run #{run["id"]} (#{inspect(other, limit: 3)})"
        )

        nil
    end
  end

  @doc """
  The test counts in a `mix test --cover` log: the last
  "N doctests, M tests, K failures" line and the "[TOTAL]" coverage, or nil.

      iex> log = "2026-10-10T02:40:00Z 170 doctests, 1119 tests, 0 failures\\n" <>
      ...>   "2026-10-10T02:40:01Z     88.12% | Total\\n"
      iex> TalesForge.PrFeed.Extras.parse_test_log(log)
      %{tests: 1119, doctests: 170, failures: 0, coverage_pct: 88.12}
      iex> TalesForge.PrFeed.Extras.parse_test_log("1 test, 1 failure\\n[TOTAL]  91.5%")
      %{tests: 1, doctests: 0, failures: 1, coverage_pct: 91.5}
      iex> TalesForge.PrFeed.Extras.parse_test_log("no summary")
      nil
  """
  @spec parse_test_log(String.t()) :: map() | nil
  def parse_test_log(log) do
    case Regex.scan(~r/(?:(\d+) doctests?, )?(\d+) tests?, (\d+) failures?/, log)
         |> List.last() do
      nil ->
        nil

      [_, doctests, tests, failures] ->
        %{
          tests: String.to_integer(tests),
          doctests: if(doctests == "", do: 0, else: String.to_integer(doctests)),
          failures: String.to_integer(failures),
          coverage_pct: coverage(log)
        }
    end
  end

  defp coverage(log) do
    case Regex.run(~r/\[TOTAL\]\s+(\d+(?:\.\d+)?)%/, log) ||
           Regex.run(~r/(\d+(?:\.\d+)?)%\s*\|\s*Total/, log) do
      [_, pct] -> pct |> Float.parse() |> elem(0)
      nil -> nil
    end
  end

  # ── The decision log ─────────────────────────────────────────────────────

  defp refresh_decisions(prev, now) do
    etag = prev && prev.etag

    case docs_token() do
      nil ->
        prev

      token ->
        case get_raw(token, "/repos/#{@docs_repo}/contents/#{@decisions_path}", etag) do
          {:ok, body, new_etag} ->
            body |> parse_decisions() |> Map.merge(%{etag: new_etag, fetched_at: now})

          :not_modified when prev != nil ->
            %{prev | fetched_at: now}

          _error ->
            prev
        end
    end
  end

  @doc """
  The decision log's entries: every `## YYYY-MM-DD` heading, total and per
  day (oldest first).

      iex> md = "# Decisions\\n\\n## 2026-10-07: A\\n\\nx\\n\\n## 2026-10-07: B\\n\\n## 2026-10-09: C\\n"
      iex> TalesForge.PrFeed.Extras.parse_decisions(md)
      %{total: 3, by_date: [%{"date" => "2026-10-07", "count" => 2}, %{"date" => "2026-10-09", "count" => 1}]}
  """
  @spec parse_decisions(String.t()) :: %{total: non_neg_integer(), by_date: [map()]}
  def parse_decisions(markdown) do
    dates =
      ~r/^## (\d{4}-\d{2}-\d{2})/m
      |> Regex.scan(markdown, capture: :all_but_first)
      |> List.flatten()

    by_date =
      dates
      |> Enum.frequencies()
      |> Enum.sort()
      |> Enum.map(fn {date, count} -> %{"date" => date, "count" => count} end)

    %{total: length(dates), by_date: by_date}
  end

  # ── HTTP ─────────────────────────────────────────────────────────────────

  defp token(nil), do: {:error, :not_configured}
  defp token(token), do: {:ok, token}

  defp docs_token do
    case Application.get_env(:ex_tales_forge, :github_docs_token) do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  defp get(token, path, params) do
    case Req.get(
           [
             url: @api <> path,
             params: params,
             auth: {:bearer, token},
             headers: [
               {"accept", "application/vnd.github+json"},
               {"x-github-api-version", "2022-11-28"}
             ],
             receive_timeout: @timeout_ms,
             connect_options: [timeout: @timeout_ms],
             retry: false
           ] ++ req_options()
         ) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, _exception} -> {:error, :unreachable}
    end
  rescue
    _ -> {:error, :unreachable}
  end

  defp get_raw(token, path, etag) do
    headers =
      [{"accept", "application/vnd.github.raw+json"}, {"x-github-api-version", "2022-11-28"}] ++
        if(etag, do: [{"if-none-match", etag}], else: [])

    case Req.get(
           [
             url: @api <> path,
             auth: {:bearer, token},
             headers: headers,
             receive_timeout: @timeout_ms,
             connect_options: [timeout: @timeout_ms],
             retry: false,
             decode_body: false
           ] ++ req_options()
         ) do
      {:ok, %Req.Response{status: 200, body: body} = resp} ->
        {:ok, body, resp |> Req.Response.get_header("etag") |> List.first()}

      {:ok, %Req.Response{status: 304}} ->
        :not_modified

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, _exception} ->
        {:error, :unreachable}
    end
  rescue
    _ -> {:error, :unreachable}
  end

  defp req_options, do: Application.get_env(:ex_tales_forge, :pr_feed_req_options, [])
end
