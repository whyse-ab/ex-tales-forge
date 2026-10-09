defmodule TalesForge.PrFeed.Poller do
  @moduledoc """
  Polls GitHub for the live PR feed (`TalesForge.PrFeed`) and publishes each
  new snapshot: stored in a public ETS table it owns (read by `TalesForge.PrFeed.snapshot/0`
  without a call to this process) and broadcast on PubSub.

  - Every `:interval_ms` (config `TalesForge.PrFeed`, default 60 s), plus once
    right after start. `:poll` false (tests) starts the table but never polls.
  - Per resource it keeps the last `ETag` and the parsed answer, so an
    unchanged answer (304) is reused and costs no rate limit.
  - No token: nothing is fetched, the snapshot is `:not_configured`.
  - The pull requests can't be fetched: `:unavailable`. CI or main's commits
    missing only blank out the CI badges or the deploy status.
  - Each poll is one pass in this process; a crash restarts it under the
    application supervisor with an empty feed.
  """

  use GenServer

  require Logger

  alias TalesForge.PrFeed
  alias TalesForge.PrFeed.GitHub
  alias TalesForge.PrFeed.Parse
  alias TalesForge.PrFeed.Versions

  @default_interval_ms 60_000

  @typedoc "The last ETag and parsed answer per resource."
  @type cache :: %{optional(GitHub.resource()) => {String.t() | nil, term()}}

  @doc "Starts the poller (named `#{inspect(__MODULE__)}`)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  @spec init(keyword()) :: {:ok, cache()}
  def init(_opts) do
    :ets.new(__MODULE__, [:named_table, :public, :set, read_concurrency: true])
    if PrFeed.config(:poll, true), do: send(self(), :poll)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll, cache) do
    {snapshot, cache} = poll(cache, DateTime.utc_now())
    PrFeed.publish(snapshot)
    Process.send_after(self(), :poll, PrFeed.config(:interval_ms, @default_interval_ms))
    {:noreply, cache}
  end

  @doc """
  One poll: fetches what changed (sending the cached ETags), builds the
  snapshot at `now` and returns it with the updated cache. Doesn't publish.
  """
  @spec poll(cache(), DateTime.t()) :: {PrFeed.snapshot(), cache()}
  def poll(cache, %DateTime{} = now) do
    if PrFeed.configured?() do
      fetch_all(cache, now)
    else
      {PrFeed.empty(:not_configured, now), %{}}
    end
  end

  defp fetch_all(cache, now) do
    case fetch(:pulls, cache, &Parse.pulls/1) do
      {:ok, pulls, cache} ->
        {ci, cache} = optional(:ci, cache, &Parse.ci_runs/1)
        {main, cache} = optional(:main, cache, &Parse.commit_shas/1)
        inputs = %{pulls: pulls, ci: ci, main: main, running: Versions.running()}
        {PrFeed.build(inputs, now), cache}

      {:error, reason} ->
        Logger.warning("PR feed: GitHub pull requests unavailable (#{inspect(reason)})")
        {PrFeed.empty(:unavailable, now), cache}
    end
  end

  defp optional(resource, cache, parse) do
    case fetch(resource, cache, parse) do
      {:ok, value, cache} -> {value, cache}
      {:error, _reason} -> {nil, Map.delete(cache, resource)}
    end
  end

  defp fetch(resource, cache, parse) do
    {etag, kept} = Map.get(cache, resource, {nil, nil})

    case GitHub.fetch(resource, etag) do
      {:ok, body, new_etag} ->
        value = parse.(body)
        {:ok, value, Map.put(cache, resource, {new_etag, value})}

      :not_modified when kept != nil ->
        {:ok, kept, cache}

      :not_modified ->
        {:error, :not_modified_without_copy}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
