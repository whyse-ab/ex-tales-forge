defmodule TalesForge.Online.Peer do
  @moduledoc """
  Production's copy of the founders online on playtest, for
  `TalesForge.Online.founders/0`.

  On production with `COSTS_PEER_TOKEN` set, it asks playtest's
  `GET /internal/online` every 10 s (2 s timeout, no retries,
  no redirects) and keeps the answer. An answer older than `ttl_ms/0` counts as
  empty, so a founder never stays "online" when playtest is down. On playtest
  and locally it never polls.

  It also owns a small ETS table with each bot's latest board API call
  (`TalesForge.Online.bot_seen/1`).
  """

  use GenServer

  alias TalesForge.AppRole
  alias TalesForge.Online

  @path "/internal/online"
  @interval_ms 10_000
  @ttl_ms 30_000
  @timeout_ms 2_000
  @table __MODULE__

  @doc "How long playtest's last answer counts, in milliseconds."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms, do: @ttl_ms

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The URL production reads: playtest's base URL plus `#{@path}`."
  @spec url() :: String.t()
  def url, do: String.trim_trailing(AppRole.base_url(:playtest), "/") <> @path

  @doc "Playtest's founders while the last answer is fresh, otherwise `[]`."
  @spec founders(DateTime.t()) :: [Online.founder()]
  def founders(now \\ DateTime.utc_now()) do
    case lookup(:peer) do
      {list, %DateTime{} = at} ->
        if DateTime.diff(now, at, :millisecond) <= @ttl_ms, do: list, else: []

      _ ->
        []
    end
  end

  @doc "Stores playtest's answer, as fetched at `at`; broadcasts a change."
  @spec put(list(), DateTime.t()) :: :ok
  def put(list, %DateTime{} = at) do
    old = founders(at)
    insert({:peer, {list, at}})
    if strip(old) != strip(list), do: Online.broadcast_changed()
    :ok
  end

  defp strip(list), do: Enum.map(list, &Map.take(&1, [:email, :page, :app]))

  @doc false
  @spec bot_seen(atom(), DateTime.t()) :: :ok
  def bot_seen(bot, at) do
    insert({{:bot, bot}, at})
    :ok
  end

  @doc false
  @spec bot_calls() :: %{optional(atom()) => DateTime.t()}
  def bot_calls do
    if :ets.whereis(@table) == :undefined,
      do: %{},
      else: Map.new(:ets.match(@table, {{:bot, :"$1"}, :"$2"}), fn [b, at] -> {b, at} end)
  end

  @doc """
  Fetches playtest's list once. `{:ok, founders}`, or `{:error, reason}` when
  the token is unset or playtest does not answer well. Never raises.
  """
  @spec fetch() :: {:ok, [Online.founder()]} | {:error, term()}
  def fetch do
    case AppRole.peer_token() do
      nil -> {:error, :not_configured}
      token -> request(token)
    end
  end

  defp request(token) do
    case Req.get(
           [
             url: url(),
             auth: {:bearer, token},
             receive_timeout: @timeout_ms,
             connect_options: [timeout: @timeout_ms],
             retry: false,
             redirect: false
           ] ++ Application.get_env(:ex_tales_forge, :online_peer_req_options, [])
         ) do
      {:ok, %Req.Response{status: 200, body: %{"founders" => list}}} when is_list(list) ->
        {:ok, list |> Online.normalize() |> Enum.map(&%{&1 | app: "playtest"})}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, _} ->
        {:error, :unreachable}
    end
  rescue
    _ -> {:error, :unreachable}
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    if polls?(), do: send(self(), :poll)
    {:ok, nil}
  end

  @impl true
  def handle_info(:poll, state) do
    case fetch() do
      {:ok, list} -> put(list, DateTime.utc_now())
      _ -> :ok
    end

    Process.send_after(self(), :poll, @interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp polls?, do: AppRole.role() == :production and AppRole.peer_token() != nil

  defp lookup(key) do
    case :ets.whereis(@table) != :undefined and :ets.lookup(@table, key) do
      [{^key, value}] -> value
      _ -> nil
    end
  end

  defp insert(tuple) do
    if :ets.whereis(@table) != :undefined, do: :ets.insert(@table, tuple)
    :ok
  end
end
