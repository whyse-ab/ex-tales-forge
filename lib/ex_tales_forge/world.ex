defmodule TalesForge.World do
  @moduledoc """
  World agents prototype (`WORLD_AGENTS=on`, default off; design sketch in
  tales-forge-docs `docs/design-world-agents.md`).

  Persons, locations (nested: Valley Inn < Tin Valley village < Tin Valley)
  and items are `TalesForge.World.Agent` processes holding their own facts.
  Each turn:

  1. `collect/2` (step `turn.world_facts`, call_type function): start or find
     the agents relevant to this turn: the location chain of where the
     character is, the persons present, the items they hold; return their
     state in budget order (here, persons, parent locations).
  2. `prompt_section/1`: at most #{12} facts / #{1_200} characters, as typed
     lines in the per-turn section only (never the cached prefix).
  3. `TalesForge.World.Prices` (step `turn.prices`): prices the player's
     words mention are quoted, or charged, by the server, not the GM.
  4. After the turn, off the critical path, `TalesForge.World.Extract` (one
     small LLM call, purpose `fact_extract`, conv id `<session>:facts`) reads
     the finished narration for new facts and promises. `validate_facts/3`
     checks them, `store_facts/3` persists them as `world_fact` session
     events (player_aware false) and `commit/3` hands them to the running
     agents; a restarted agent rehydrates them from those events.

  Pack facts come from `priv/adventures/<id>/world_agents.json`; a pack
  without one gets agents with no pack facts (GM facts still accumulate).
  """

  require Logger

  alias TalesForge.Config
  alias TalesForge.Game.World, as: GameWorld
  alias TalesForge.NPC
  alias TalesForge.Repo
  alias TalesForge.Schemas.SessionEvent
  alias TalesForge.World.Agent

  import Ecto.Query

  @max_facts 12
  @max_chars 1_200
  @gm_facts_per_entity 4
  @kinds ~w(fact price promise)
  @fact_event "world_fact"

  def enabled?, do: Config.world_agents?()

  def kinds, do: @kinds

  @doc "Pack definitions for an adventure: `%{locations: %{id => def}, persons: ..., items: ...}`."
  def definitions(adventure_id) when is_binary(adventure_id) do
    key = {__MODULE__, :defs, adventure_id}

    case :persistent_term.get(key, nil) do
      nil ->
        defs = load_definitions(adventure_id)
        :persistent_term.put(key, defs)
        defs

      defs ->
        defs
    end
  end

  def definitions(_adventure_id), do: %{locations: %{}, persons: %{}, items: %{}}

  defp load_definitions(adventure_id) do
    path =
      Path.join([
        :code.priv_dir(:ex_tales_forge),
        "adventures",
        adventure_id,
        "world_agents.json"
      ])

    raw = if File.exists?(path), do: path |> File.read!() |> Jason.decode!(), else: %{}

    by_id = fn key -> raw |> Map.get(key, []) |> Map.new(&{&1["id"], &1}) end
    %{locations: by_id.("locations"), persons: by_id.("persons"), items: by_id.("items")}
  end

  # --- 1. collect ------------------------------------------------------------------

  @doc """
  The agents relevant to this turn, started lazily, as plain maps in budget
  order, each with a `:role` (`:here`, `:present`, `:held` or `:around`).
  """
  def collect(session_id, world) do
    defs = definitions(world["adventure_id"])
    stored = stored_facts(session_id)
    moods = world["npc_moods"] || %{}
    here = get_in(world, ["character", "location_id"])
    [_ | parents] = chain = location_chain(defs, here)

    persons = List.wrap(world["present_npcs"])
    names = if persons == [], do: %{}, else: person_names(session_id)

    held =
      world
      |> get_in(["character", "inventory"])
      |> List.wrap()
      |> Enum.map(&item_id/1)
      |> Enum.filter(&Map.has_key?(defs.items, &1))

    specs =
      Enum.map(Enum.take(chain, 1), &{&1, :here, :location}) ++
        Enum.map(persons, &{&1, :present, :person}) ++
        Enum.map(held, &{&1, :held, :item}) ++
        Enum.map(parents, &{&1, :around, :location})

    specs
    |> Enum.reject(fn {id, _, _} -> is_nil(id) end)
    |> Enum.uniq_by(fn {id, _, _} -> id end)
    |> Enum.flat_map(fn {id, role, kind} ->
      initial = initial_state(session_id, id, kind, defs, stored, moods, names, world)

      case ensure(initial) do
        {:ok, pid} -> [pid |> Agent.state() |> Map.from_struct() |> Map.put(:role, role)]
        :error -> []
      end
    end)
  end

  defp location_chain(_defs, nil), do: [nil]

  defp location_chain(defs, id) do
    Stream.unfold(id, fn
      nil -> nil
      current -> {current, get_in(defs.locations, [current, "parent"])}
    end)
    |> Enum.take(5)
  end

  defp person_names(session_id) do
    session_id
    |> NPC.list_instances()
    |> Map.new(&{&1.npc_id, get_in(&1.personality || %{}, ["name"]) || &1.npc_id})
  end

  defp item_id(%{"id" => id}), do: id
  defp item_id(id) when is_binary(id), do: id
  defp item_id(_), do: nil

  defp initial_state(session_id, id, kind, defs, stored, moods, names, world) do
    definition =
      case kind do
        :location -> Map.get(defs.locations, id, %{})
        :person -> Map.get(defs.persons, id, %{})
        :item -> Map.get(defs.items, id, %{})
      end

    name =
      definition["name"] ||
        case kind do
          :location -> GameWorld.runtime_location(world, id)["name"]
          :person -> names[id]
          :item -> nil
        end

    pack_facts = Enum.map(definition["facts"] || [], &Map.put(&1, "source", "pack"))
    gm_facts = Map.get(stored, id, [])

    %Agent{
      session_id: session_id,
      id: id,
      kind: kind,
      name: name || id,
      parent: definition["parent"],
      facts: pack_facts ++ gm_facts,
      mood: if(kind == :person, do: moods[id])
    }
  end

  defp ensure(%Agent{} = initial) do
    case Agent.whereis(initial.session_id, initial.id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case DynamicSupervisor.start_child(TalesForge.World.Supervisor, {Agent, initial}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> log_error(initial, other)
        end
    end
  catch
    :exit, reason -> log_error(initial, reason)
  end

  defp log_error(initial, reason) do
    Logger.warning("world agent unavailable id=#{initial.id} reason=#{inspect(reason)}")
    :error
  end

  # --- 2. prompt -------------------------------------------------------------------

  @doc "Per-turn prompt lines for the collected agents, within the budget, or nil."
  def prompt_section(nil), do: nil
  def prompt_section([]), do: nil

  def prompt_section(agents) when is_list(agents) do
    {lines, _count, _chars} =
      Enum.reduce(agents, {[], 0, 0}, fn agent, {lines, count, chars} ->
        facts = budget_facts(agent, @max_facts - count)
        texts = Enum.map(facts, &fact_text/1)
        size = texts |> Enum.map(&String.length/1) |> Enum.sum()

        cond do
          facts == [] -> {lines, count, chars}
          chars + size > @max_chars -> {lines, count, chars}
          true -> {[line(agent, texts) | lines], count + length(facts), chars + size}
        end
      end)

    case Enum.reverse(lines) do
      [] -> nil
      lines -> Enum.join(["## World facts (true in this world; keep to them)" | lines], "\n")
    end
  end

  defp budget_facts(_agent, left) when left <= 0, do: []

  defp budget_facts(agent, left) do
    {pack, gm} = Enum.split_with(agent.facts, &(&1["source"] == "pack"))
    Enum.take(pack ++ Enum.take(gm, -@gm_facts_per_entity), left)
  end

  defp fact_text(%{"kind" => "promise", "text" => text} = f),
    do: "promised: #{text}#{turn_suffix(f)}"

  defp fact_text(%{"source" => "narration", "text" => text} = f), do: text <> turn_suffix(f)
  defp fact_text(%{"text" => text}), do: text

  defp turn_suffix(%{"turn" => turn}) when is_integer(turn), do: " (turn #{turn})"
  defp turn_suffix(_), do: ""

  defp line(agent, texts) do
    role =
      case agent.role do
        :here -> "here"
        :present -> "present"
        :held -> "carried"
        :around -> "around"
      end

    "- #{agent.name} [#{agent.id}] (#{role}): " <> Enum.join(texts, "; ")
  end

  # --- 3. new facts ---------------------------------------------------------------

  @doc """
  Validates new facts (`%{"about", "kind", "text"}`, from the extraction call)
  against this turn's agents. Returns `{accepted, rejected}`; accepted is
  `[{entity_id, fact}]`, rejected is `[{new_fact, reason}]`.
  """
  def validate_facts(_agents, [], _turn_number), do: {[], []}

  def validate_facts(agents, new_facts, turn_number) do
    {accepted_rev, rejected_rev, _seen} =
      Enum.reduce(new_facts, {[], [], MapSet.new()}, fn nf, {acc, rej, seen} ->
        case validate(nf, agents, seen, turn_number) do
          {:ok, id, fact} ->
            {[{id, fact} | acc], rej, MapSet.put(seen, {id, normalize(fact["text"])})}

          {:error, reason} ->
            {acc, [{nf, reason} | rej], seen}
        end
      end)

    {Enum.reverse(accepted_rev), Enum.reverse(rejected_rev)}
  end

  @doc "Persists accepted facts as `world_fact` session events (never shown to the player)."
  def store_facts(_session_id, [], _tick), do: :ok

  def store_facts(session_id, accepted, tick) do
    Enum.each(accepted, fn {id, fact} ->
      %SessionEvent{}
      |> SessionEvent.changeset(%{
        game_session_id: session_id,
        kind: @fact_event,
        actor: "world",
        player_aware: false,
        tick: tick || 0,
        payload: %{"entity_id" => id, "fact" => fact}
      })
      |> Repo.insert!()
    end)
  end

  @doc "The session's stored facts by entity id, oldest first."
  def stored_facts(session_id) do
    Repo.all(
      from e in SessionEvent,
        where: e.game_session_id == ^session_id and e.kind == ^@fact_event,
        order_by: [asc: e.inserted_at],
        select: e.payload
    )
    |> Enum.group_by(& &1["entity_id"], & &1["fact"])
  end

  defp validate(nf, agents, seen, turn_number) do
    text = nf["text"] |> to_string() |> String.trim()
    kind = if nf["kind"] in @kinds, do: nf["kind"], else: "fact"

    with {:ok, agent} <- resolve(nf["about"], agents),
         :ok <- check(text != "", :empty),
         :ok <- check(kind != "promise" or agent.kind == :person, :promise_not_person),
         :ok <- check(not duplicate?(agent, text, seen), :duplicate),
         :ok <- check(kind != "price" or not price_conflict?(agent, text), :price_conflict) do
      {:ok, agent.id,
       %{"kind" => kind, "text" => text, "source" => "narration", "turn" => turn_number}}
    end
  end

  defp check(true, _reason), do: :ok
  defp check(false, reason), do: {:error, reason}

  defp resolve(about, agents) do
    # The prompt shows ids as "[valley_inn]"; the GM sometimes copies the brackets.
    key =
      about
      |> to_string()
      |> String.trim()
      |> String.trim("[")
      |> String.trim("]")
      |> String.downcase()

    found =
      if key == "here",
        do: Enum.find(agents, &(&1.role == :here)),
        else:
          Enum.find(agents, &(String.downcase(&1.id) == key)) ||
            Enum.find(agents, &(String.downcase(to_string(&1.name)) == key))

    if found, do: {:ok, found}, else: {:error, :unknown_entity}
  end

  defp duplicate?(agent, text, seen) do
    norm = normalize(text)

    MapSet.member?(seen, {agent.id, norm}) or
      Enum.any?(agent.facts, &(normalize(&1["text"]) == norm))
  end

  # A price for something that already has one is rejected: the pack (or the
  # first GM price) wins. "Private room: 3 silver" vs "Room for the night: 2 silver".
  defp price_conflict?(agent, text) do
    new_key = price_key(text)

    agent.facts
    |> Enum.filter(&(&1["kind"] == "price"))
    |> Enum.any?(&(not MapSet.disjoint?(price_key(&1["text"]), new_key)))
  end

  @stop ~w(a an the of for per and with night nights one bowl mug)
  defp price_key(text) do
    text
    |> to_string()
    |> String.split(":", parts: 2)
    |> hd()
    |> String.downcase()
    |> String.split(~r/[^a-z]+/, trim: true)
    |> Enum.reject(&(&1 in @stop or String.length(&1) < 3))
    |> Enum.map(&String.trim_trailing(&1, "s"))
    |> MapSet.new()
  end

  defp normalize(text),
    do:
      text
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, " ")
      |> String.trim()

  # --- 4. commit -------------------------------------------------------------------

  @doc "After the turn is persisted: accepted facts and new moods go to the running agents."
  def commit(session_id, accepted, reactions) do
    accepted
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn {id, facts} -> call(session_id, id, &Agent.add_facts(&1, facts)) end)

    Enum.each(reactions, fn r ->
      mood = Map.take(r, ~w(emotion intensity stance confidence turn_number))
      call(session_id, r["npc_id"], &Agent.put_mood(&1, mood))
    end)

    :ok
  end

  defp call(session_id, id, fun) do
    case Agent.whereis(session_id, id) do
      nil -> :ok
      pid -> fun.(pid)
    end
  catch
    :exit, _ -> :ok
  end
end
