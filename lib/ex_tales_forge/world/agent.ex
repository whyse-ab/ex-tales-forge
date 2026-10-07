defmodule TalesForge.World.Agent do
  @moduledoc """
  One world entity of one session (prototype, `WORLD_AGENTS=on`): a person, a
  location or an item, holding its own facts. Started lazily by
  `TalesForge.World` under `TalesForge.World.Supervisor`, registered in
  `TalesForge.World.Registry` as `{session_id, entity_id}`, stopped after
  #{div(30 * 60_000, 60_000)} idle minutes.

  The agent never touches the database. It starts from the pack definition
  plus the session's stored facts (`world_fact` session events) and mood
  (`world_state["npc_moods"]`), and `TalesForge.World.commit/3` adds facts
  only after they are persisted, so a restarted agent rehydrates the same state.
  """
  use GenServer, restart: :transient

  @idle_ms 30 * 60_000

  defstruct [:session_id, :id, :kind, :name, :parent, facts: [], mood: nil]

  @typedoc "An entity's state: its id, kind, display name, parent location, facts and mood."
  @type t :: %__MODULE__{
          session_id: String.t() | nil,
          id: String.t() | nil,
          kind: :person | :location | :item | nil,
          name: String.t() | nil,
          parent: String.t() | nil,
          facts: [map()],
          mood: map() | nil
        }

  @doc "Starts the agent for `state.session_id` and `state.id`, registered under `via/2`."
  @spec start_link(t()) :: GenServer.on_start()
  def start_link(%__MODULE__{} = state) do
    GenServer.start_link(__MODULE__, state, name: via(state.session_id, state.id))
  end

  @doc "The registry name of a session's entity."
  @spec via(String.t(), String.t()) :: {:via, Registry, {module(), {String.t(), String.t()}}}
  def via(session_id, id), do: {:via, Registry, {TalesForge.World.Registry, {session_id, id}}}

  @doc "The pid of a running agent, or `nil` if it isn't running."
  @spec whereis(String.t(), String.t()) :: pid() | nil
  def whereis(session_id, id) do
    case Registry.lookup(TalesForge.World.Registry, {session_id, id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "The agent's current state."
  @spec state(GenServer.server()) :: t()
  def state(pid), do: GenServer.call(pid, :state)

  @doc "Appends facts (already validated and persisted by `TalesForge.World`)."
  @spec add_facts(GenServer.server(), [map()]) :: :ok
  def add_facts(pid, facts), do: GenServer.call(pid, {:add_facts, facts})

  @doc "Replaces the agent's mood (a person's latest NPC reaction)."
  @spec put_mood(GenServer.server(), map()) :: :ok
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
