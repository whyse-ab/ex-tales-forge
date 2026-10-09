defmodule TalesForge.PrFeed.GitHub do
  @moduledoc """
  The GitHub REST calls of the live PR feed, server-side only, with the feed
  token (`TalesForge.PrFeed.token/0`) as a bearer token.

  Every call sends the `ETag` of the previous answer as `If-None-Match`; GitHub
  then answers `304 Not Modified`, which doesn't count against the rate limit,
  and the caller keeps its parsed copy. Short timeouts and no retries: a slow
  or broken GitHub makes the feed say "unavailable", nothing else.

  The three resources (`t:resource/0`) need the token permissions *Pull
  requests: read*, *Contents: read* and *Actions: read* on the repo.

  The pull requests and main's commits are read page by page
  (`fetch/3`, 100 per page), so the poller can count all of them
  (`TalesForge.PrFeed.Pace`); each page has its own `ETag`. Pull requests
  come newest first by creation, so a merge changes only the page it is on.
  """

  alias TalesForge.PrFeed

  @api "https://api.github.com"
  @timeout_ms 5_000
  @per_page 100

  @typedoc "What the feed fetches."
  @type resource :: :pulls | :main | :ci

  @typedoc "Why a fetch failed."
  @type error :: :not_configured | :unreachable | {:http_status, non_neg_integer()}

  @doc """
  The request path and query of `resource` for `repo`.

      iex> TalesForge.PrFeed.GitHub.path(:pulls, "o/r")
      {"/repos/o/r/pulls", [state: "all", sort: "created", direction: "desc", per_page: 100]}
      iex> TalesForge.PrFeed.GitHub.path(:main, "o/r")
      {"/repos/o/r/commits", [sha: "main", per_page: 100]}
      iex> TalesForge.PrFeed.GitHub.path(:ci, "o/r")
      {"/repos/o/r/actions/workflows/ci.yml/runs", [event: "pull_request", per_page: 100]}
  """
  @spec path(resource(), String.t()) :: {String.t(), keyword()}
  def path(:pulls, repo),
    do:
      {"/repos/#{repo}/pulls",
       [state: "all", sort: "created", direction: "desc", per_page: @per_page]}

  def path(:main, repo), do: {"/repos/#{repo}/commits", [sha: "main", per_page: @per_page]}

  def path(:ci, repo),
    do: {"/repos/#{repo}/actions/workflows/ci.yml/runs", [event: "pull_request", per_page: 100]}

  @doc "How many entries a page of a list holds (GitHub's maximum)."
  @spec per_page() :: pos_integer()
  def per_page, do: @per_page

  @doc """
  Fetches `page` (from 1) of `resource`. `etag` is the previous answer's
  `ETag` for that page (or nil). Returns `{:ok, body, etag}`, `:not_modified`
  (304: keep the copy you have) or `{:error, reason}`. Never raises.
  """
  @spec fetch(resource(), String.t() | nil, pos_integer()) ::
          {:ok, term(), String.t() | nil} | :not_modified | {:error, error()}
  def fetch(resource, etag \\ nil, page \\ 1) do
    case PrFeed.token() do
      nil -> {:error, :not_configured}
      token -> request(resource, etag, page, token)
    end
  end

  defp request(resource, etag, page, token) do
    {path, params} = path(resource, PrFeed.repo())
    params = if page > 1, do: params ++ [page: page], else: params

    headers =
      [
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", "2022-11-28"}
      ] ++ if(etag, do: [{"if-none-match", etag}], else: [])

    case Req.get(
           [
             url: @api <> path,
             params: params,
             auth: {:bearer, token},
             headers: headers,
             receive_timeout: @timeout_ms,
             connect_options: [timeout: @timeout_ms],
             retry: false
           ] ++ req_options()
         ) do
      {:ok, %Req.Response{status: 200, body: body} = resp} -> {:ok, body, etag(resp)}
      {:ok, %Req.Response{status: 304}} -> :not_modified
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, _exception} -> {:error, :unreachable}
    end
  rescue
    _ -> {:error, :unreachable}
  end

  defp etag(resp) do
    case Req.Response.get_header(resp, "etag") do
      [etag | _] -> etag
      [] -> nil
    end
  end

  # Test hook: config :ex_tales_forge, :pr_feed_req_options, plug: {Req.Test, ...}
  defp req_options, do: Application.get_env(:ex_tales_forge, :pr_feed_req_options, [])
end
