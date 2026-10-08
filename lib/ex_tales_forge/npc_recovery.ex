defmodule TalesForge.NPCRecovery do
  @moduledoc """
  Restores NPC Jido agents for active sessions after application boot.

  The boot sync syncs every `active` session in the database. Set
  `config :ex_tales_forge, :npc_recovery_on_boot, false` (default `true`) to skip
  it: the process still starts and an explicit recover call still syncs, but
  nothing is synced at boot. Offline tools that start the app only for its config, Repo and
  HTTP clients (`mix intent.eval`) set it so they leave the sessions alone.
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias TalesForge.NPCRegistry
  alias TalesForge.Repo
  alias TalesForge.Schemas.GameSession

  @doc "Starts the recovery server; it syncs active sessions at boot unless disabled."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  @spec recover_now() :: {:ok, non_neg_integer()}
  def recover_now do
    GenServer.call(__MODULE__, :recover)
  end

  @impl true
  def init(_opts) do
    if boot_sync?(), do: send(self(), :recover)
    {:ok, %{}}
  end

  @doc "True unless `config :ex_tales_forge, :npc_recovery_on_boot` is `false`."
  @spec boot_sync?() :: boolean()
  def boot_sync?, do: Application.get_env(:ex_tales_forge, :npc_recovery_on_boot, true) != false

  @impl true
  def handle_info(:recover, state) do
    recover_active_sessions()
    {:noreply, state}
  end

  @impl true
  def handle_call(:recover, _from, state) do
    result = recover_active_sessions()
    {:reply, result, state}
  end

  defp recover_active_sessions do
    started = System.monotonic_time(:millisecond)

    count =
      GameSession
      |> where([s], s.status == "active")
      |> Repo.all()
      |> Enum.reduce(0, fn session, acc ->
        case NPCRegistry.sync(session) do
          :ok -> acc + 1
          _ -> acc
        end
      end)

    elapsed = System.monotonic_time(:millisecond) - started
    Logger.info("npc recovery synced sessions=#{count} duration_ms=#{elapsed}")
    {:ok, count}
  end
end
