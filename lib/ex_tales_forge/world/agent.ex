defmodule TalesForge.World.Agent do
  @moduledoc """
  One world entity of one session (prototype, `WORLD_AGENTS=on`): a person, a
  location or an item, holding its own facts. Started lazily by
  `TalesForge.World` under `TalesForge.World.Supervisor`, registered in
  `TalesForge.World.Registry` as `{session_id, entity_id}`, stopped after
  #{div(30 * 60_000, 60_000)} idle minutes.

  The agent never touches the database. It starts from the pack definition
  plus the session's persisted snapshot (`world_state["world_agents"]`), and
  `TalesForge.World.commit/3` adds facts only after the turn that produced
  them is persisted, so a restarted agent rehydrates exactly what the player saw.
  """
  use GenServer, restart: :transient

  @idle_ms 30 * 60_000

  defstruct [:session_id, :id, :kind, :name, :parent, facts: [], mood: nil]

  def start_link(%__MODULE__{} = state) do
    GenServer.start_link(__MODULE__, state, name: via(state.session_id, state.id))
  end

  def via(session_id, id), do: {:via, Registry, {TalesForge.World.Registry, {session_id, id}}}

  def whereis(session_id, id) do
    case Registry.lookup(TalesForge.World.Registry, {session_id, id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def state(pid), do: GenServer.call(pid, :state)
  def add_facts(pid, facts), do: GenServer.call(pid, {:add_facts, facts})
  def put_mood(pid, mood), do: GenServer.call(pid, {:put_mood, mood})

  @impl true
  def init(state), do: {:ok, state, @idle_ms}

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state, @idle_ms}

  def handle_call({:add_facts, facts}, _from, state),
    do: {:reply, :ok, %{state | facts: state.facts ++ facts}, @idle_ms}

  def handle_call({:put_mood, mood}, _from, state),
    do: {:reply, :ok, %{state | mood: mood}, @idle_ms}

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}
end
