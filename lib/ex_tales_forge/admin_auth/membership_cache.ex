defmodule TalesForge.AdminAuth.MembershipCache do
  @moduledoc """
  Tiny TTL cache (public ETS table) for GitHub team-membership lookups, so the
  admin recheck on every request / LiveView mount doesn't call GitHub each time.
  The GenServer only owns the table; reads and writes go straight to ETS.
  """

  use GenServer

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Returns `{:ok, value}` for a live entry, `:miss` otherwise."
  def get(key) do
    now = now_ms()

    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now -> {:ok, value}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  def put(key, value, ttl_ms) do
    :ets.insert(@table, {key, value, now_ms() + ttl_ms})
    value
  rescue
    ArgumentError -> value
  end

  def clear do
    :ets.delete_all_objects(@table)
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
