defmodule TalesForge.Survey.Cache do
  @moduledoc """
  Short TTL cache (public ETS table) for loaded survey definitions, so a page
  load doesn't call GitHub every time. Expired entries are kept as the "last
  good" copy: when GitHub is down or a docs commit breaks the JSON,
  `TalesForge.Survey.Source` serves the stale definition with a warning.
  The GenServer only owns the table; reads and writes go straight to ETS.
  """

  use GenServer

  @table __MODULE__

  @doc "Starts the table owner."
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "`{:fresh, value}` before the TTL ran out, `{:stale, value}` after, `:miss` if never set."
  @spec get(term()) :: {:fresh, term()} | {:stale, term()} | :miss
  def get(key) do
    now = now_ms()

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now -> {:fresh, value}
      [{^key, value, _expires_at}] -> {:stale, value}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc "Stores `value` under `key` for `ttl_ms`; returns `value`."
  @spec put(term(), value, non_neg_integer()) :: value when value: term()
  def put(key, value, ttl_ms) do
    :ets.insert(@table, {key, value, now_ms() + ttl_ms})
    value
  rescue
    ArgumentError -> value
  end

  @doc "Drops every entry (tests, and the admin 'reload' button for one key via `delete/1`)."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Drops one entry."
  @spec delete(term()) :: :ok
  def delete(key) do
    :ets.delete(@table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
