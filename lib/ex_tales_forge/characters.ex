defmodule TalesForge.Characters do
  @moduledoc """
  One Character entity for player characters and NPCs (Character plan in
  tales-forge-docs, phases 1 and 1b).

  The game still runs on `world_state["character"]` and `npc_instances`;
  nothing reads `characters` yet. This module keeps the rows in step:

    * `seed_session/2` writes them when a session is created.
    * `mirror/1` is the double-write: after every turn it copies the current
      player character and NPC state (location, sheet, stock, mood,
      relationship, runtime, memories) onto the rows. It never fails a turn.
    * `backfill/0` does the same for every existing session. Idempotent and
      re-runnable.

  All three go through `sync_session/2`: insert missing rows, update the
  mirrored fields of existing ones, add NPC memories not yet recorded. Levers
  (OCEAN, Maslow, concerns), controller, owner, origin and definition are set
  when a row is first written and are not overwritten by later syncs.
  """

  import Ecto.Query

  require Logger

  alias TalesForge.Characters.Levers
  alias TalesForge.Game.Pack
  alias TalesForge.Game.WorldClock
  alias TalesForge.NPC
  alias TalesForge.Repo
  alias TalesForge.Schemas.{Character, CharacterMemory, GameSession, NpcInstance, PlaytestRun}

  @maslow_by_need %{
    "survival" => "physiological",
    "physiological" => "physiological",
    "safety" => "safety",
    "belonging" => "belonging",
    "love" => "belonging",
    "esteem" => "esteem",
    "self_actualisation" => "self_actualisation",
    "self_actualization" => "self_actualisation"
  }

  # Columns copied from the old state on every sync. Everything else is set
  # once, when the row is first written.
  @mirrored ~w(name race role location_id stats skills inventory coins wounds wound_max
               vitality learning_points learning_failures mood relationships runtime)a

  @doc """
  Writes the session's characters at session create: the player character
  (from `world_state["character"]` plus the pack file's levers) and one per
  NPC instance. Re-running it updates the mirrored fields (`sync_session/2`).

  Options (atom or string keys):
    * `:controller` – `"player"` (default) or `"bot"` for the persona runner
    * `:controller_ref` – who controls the player character (a persona id, …)
    * `:owner_player_id` – the player the character belongs to (nil for now)
  """
  @spec seed_session(GameSession.t(), map()) :: :ok | {:error, term()}
  def seed_session(%GameSession{} = session, opts \\ %{}), do: sync_session(session, opts)

  @doc """
  Inserts or updates every character of the session from the old state, in one
  transaction, then adds NPC memories that have no row yet. Options as for
  `seed_session/2`; they only matter for rows written for the first time.
  """
  @spec sync_session(GameSession.t(), map()) :: :ok | {:error, term()}
  def sync_session(%GameSession{} = session, opts \\ %{}) do
    tick = Map.get(session.world_state, "world_tick", WorldClock.default_start_tick())
    pc = player_character_attrs(session, opts, tick)
    moods = Map.get(session.world_state, "npc_moods") || %{}
    instances = NPC.list_instances(session.id)
    npcs = Enum.map(instances, &from_npc_instance(&1, tick, pc.slug, Map.get(moods, &1.npc_id)))

    result =
      Repo.transaction(fn ->
        Enum.each([pc | npcs], &upsert_or_rollback!(&1, session.id))
        Enum.each(instances, &mirror_memories!(session.id, &1))
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, {:characters, reason}}
    end
  end

  @doc """
  The double-write after a turn: `sync_session/1` for the session as just
  persisted. Never fails the turn: an error is logged and the next turn syncs
  again. Returns `:ok`.
  """
  @spec mirror(GameSession.t()) :: :ok
  def mirror(%GameSession{} = session) do
    case sync_session(session) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("characters mirror failed session=#{session.id} reason=#{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning(
        "characters mirror crashed session=#{session.id} error=#{Exception.message(e)}"
      )

      :ok
  end

  @doc """
  Writes or refreshes the characters of every existing session. Sessions that
  ran under the persona runner get the player character as `bot` with the
  persona as `controller_ref`. Idempotent and safe to re-run.

  Returns `%{sessions: n, inserted: n, characters: n, memories: n, failed: [{session_id, reason}]}`.
  """
  @spec backfill() :: map()
  def backfill do
    before = Repo.aggregate(Character, :count)
    personas = Map.new(Repo.all(from r in PlaytestRun, select: {r.game_session_id, r.persona}))

    failed =
      GameSession
      |> order_by([g], asc: g.inserted_at)
      |> Repo.all()
      |> Enum.flat_map(fn session ->
        case sync_session(session, backfill_opts(personas[session.id])) do
          :ok -> []
          {:error, reason} -> [{session.id, reason}]
        end
      end)

    total = Repo.aggregate(Character, :count)

    %{
      sessions: Repo.aggregate(GameSession, :count),
      inserted: total - before,
      characters: total,
      memories: Repo.aggregate(CharacterMemory, :count),
      failed: failed
    }
  end

  defp backfill_opts(nil), do: %{}
  defp backfill_opts(persona), do: %{controller: "bot", controller_ref: persona}

  defp upsert_or_rollback!(attrs, session_id) do
    changeset = Character.changeset(%Character{}, Map.put(attrs, :game_session_id, session_id))

    case Repo.insert(changeset,
           on_conflict: {:replace, @mirrored ++ [:updated_at]},
           conflict_target: [:game_session_id, :slug]
         ) do
      {:ok, _} -> :ok
      {:error, changeset} -> Repo.rollback({attrs.slug, changeset})
    end
  end

  # NPC memories live in runtime_state["memories"] (the newest 20). Each one not
  # yet recorded becomes a character_memories row, matched on tick + text.
  defp mirror_memories!(session_id, %NpcInstance{} = inst) do
    memories = List.wrap((inst.runtime_state || %{})["memories"])

    if memories != [] do
      %Character{} = character = get_by_slug(session_id, inst.npc_id)

      known =
        CharacterMemory
        |> where([m], m.character_id == ^character.id)
        |> select([m], {m.tick, m.text})
        |> Repo.all()
        |> MapSet.new()

      memories
      |> Enum.map(&memory_attrs/1)
      |> Enum.reject(&(is_nil(&1) or MapSet.member?(known, {&1.tick, &1.text})))
      |> Enum.uniq_by(&{&1.tick, &1.text})
      |> Enum.each(&add_memory!(character, inst.npc_id, &1))
    end

    :ok
  end

  defp add_memory!(character, npc_id, attrs) do
    case add_memory(character, attrs) do
      {:ok, _} -> :ok
      {:error, changeset} -> Repo.rollback({npc_id, :memory, changeset})
    end
  end

  defp memory_attrs(%{} = memory) do
    case memory["summary"] || memory["what"] do
      text when is_binary(text) and text != "" ->
        %{
          kind: "memory",
          text: String.trim(text),
          felt: memory["felt"],
          secret: memory["secret"] == true,
          tick: if(is_integer(memory["tick"]), do: memory["tick"])
        }

      _ ->
        nil
    end
  end

  defp memory_attrs(_), do: nil

  @doc "The session's characters, ordered by slug."
  def list_for_session(session_id) do
    Character
    |> where([c], c.game_session_id == ^session_id)
    |> order_by([c], asc: c.slug)
    |> Repo.all()
  end

  @doc "One character by session and slug, or nil."
  def get_by_slug(session_id, slug),
    do: Repo.get_by(Character, game_session_id: session_id, slug: slug)

  @doc """
  Adds one memory row for a character: its own view (felt, salience, secret)
  of an event, optionally pointing at the shared `session_events` row.
  """
  def add_memory(%Character{id: id}, attrs) when is_map(attrs) do
    %CharacterMemory{}
    |> CharacterMemory.changeset(Map.put(attrs, :character_id, id))
    |> Repo.insert()
  end

  @doc "A character's memories, oldest first."
  def list_memories(%Character{id: id}) do
    CharacterMemory
    |> where([m], m.character_id == ^id)
    |> order_by([m], asc: m.tick, asc: m.inserted_at)
    |> Repo.all()
  end

  @doc """
  Character attrs for the player character: the sheet as stored in
  `world_state["character"]` plus the levers from the adventure's pack file.
  """
  @spec player_character_attrs(GameSession.t(), map(), integer()) :: map()
  def player_character_attrs(%GameSession{world_state: world_state}, opts, tick) do
    adventure_id = Map.get(world_state, "adventure_id") || "crossroads_ledger"
    file = player_character_file(adventure_id)
    sheet = Map.get(world_state, "character") || Pack.sheet(file)
    controller = opt(opts, :controller) || "player"

    %{
      slug: sheet["id"] || file["id"],
      controller: controller,
      controller_ref: opt(opts, :controller_ref),
      owner_player_id: opt(opts, :owner_player_id),
      origin: %{"source" => "pack", "adventure_id" => adventure_id, "definition_id" => file["id"]},
      definition: file,
      name: sheet["name"],
      race: sheet["race"],
      role: nil,
      location_id: sheet["location_id"] || world_state["location_id"],
      stats: Character.Stats.from_sheet(sheet["stats"]),
      skills: int_map(sheet["skills"]),
      ocean: Levers.ocean_source(file),
      maslow_level: file["maslow"] || "safety",
      maslow_since_tick: tick,
      concerns: concerns(file["concerns"], tick),
      inventory: inventory(sheet["inventory"]),
      coins: sheet["coins"] || %{},
      wounds: int(sheet["wounds"], 0),
      wound_max: int(sheet["wound_max"], 3),
      vitality: sheet["vitality"] || "ok",
      learning_points: sheet["learning_points"] || %{},
      learning_failures: sheet["learning_failures"] || %{},
      mood: nil,
      relationships: %{},
      runtime: %{}
    }
  end

  @doc """
  Character attrs for an NPC instance (controller `gm`). Stats default to 10
  and OCEAN to 5 when the definition has none; the Maslow level falls back to
  the legacy `primary_need`.
  """
  @spec from_npc_instance(NpcInstance.t(), integer(), String.t() | nil, map() | nil) :: map()
  def from_npc_instance(%NpcInstance{} = inst, tick, pc_slug \\ nil, reaction \\ nil) do
    definition = inst.personality || %{}
    runtime = inst.runtime_state || %{}

    %{
      slug: inst.npc_id,
      controller: "gm",
      controller_ref: nil,
      owner_player_id: nil,
      origin: %{"source" => "pack", "definition_id" => inst.npc_id},
      definition: definition,
      name: definition["name"] || inst.npc_id,
      race: definition["race"],
      role: definition["role"],
      location_id: runtime["location_id"] || definition["default_location_id"],
      stats: Character.Stats.from_sheet(definition["stats"]),
      skills: int_map(definition["skills"]),
      ocean: Levers.ocean_source(definition),
      maslow_level: maslow_level(definition),
      maslow_since_tick: tick,
      concerns: npc_concerns(definition, runtime, tick),
      inventory: inventory(runtime["stock"]),
      coins: definition["coins"] || %{},
      mood: runtime["mood"],
      relationships: relationships(runtime, pc_slug),
      runtime: npc_runtime(runtime, reaction)
    }
  end

  defp maslow_level(definition) do
    definition["maslow"] ||
      Map.get(@maslow_by_need, get_in(definition, ["motivations", "primary_need"])) ||
      "safety"
  end

  defp concerns(list, tick) do
    list
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) and is_binary(&1["text"])))
    |> Enum.take(Levers.max_concerns())
    |> Enum.map(&Map.put_new(&1, "since_tick", tick))
  end

  # Sessions from before the pack levers have no `concerns`: use the legacy
  # current_concern so the row still says what the NPC is after.
  defp npc_concerns(%{"concerns" => list}, _runtime, tick) when is_list(list),
    do: concerns(list, tick)

  defp npc_concerns(_definition, runtime, tick) do
    case runtime["current_concern"] do
      %{"focus" => focus} = c when is_binary(focus) and focus != "" ->
        [
          %{
            "text" => focus,
            "focus" => focus,
            "priority" => clamp_priority(c["priority"]),
            "since_tick" => c["since_tick"] || tick
          }
        ]

      _ ->
        []
    end
  end

  defp clamp_priority(p) when is_integer(p), do: p |> max(1) |> min(10)
  defp clamp_priority(_), do: 5

  defp npc_runtime(runtime, reaction) do
    runtime
    |> Map.take(~w(since_tick resources public_facts concern_wait_ticks current_concern))
    |> then(fn r -> if is_map(reaction), do: Map.put(r, "reaction", reaction), else: r end)
  end

  # Old sheets can hold items without an id, or a quantity as a string.
  defp inventory(items) do
    items
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"name" => name} = item when is_binary(name) and name != "" ->
        [
          %{
            "id" =>
              item["id"] || name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_"),
            "name" => name,
            "quantity" => int(item["quantity"], 1),
            "price_copper" => if(is_integer(item["price_copper"]), do: item["price_copper"])
          }
        ]

      _ ->
        []
    end)
  end

  defp int_map(map) when is_map(map) do
    for {k, v} <- map, is_integer(v) or is_float(v), into: %{}, do: {to_string(k), trunc(v)}
  end

  defp int_map(_), do: %{}

  defp int(v, _default) when is_integer(v), do: v
  defp int(v, _default) when is_float(v), do: trunc(v)

  defp int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp int(_, default), do: default

  defp player_character_file(adventure_id) do
    Pack.player_character!(adventure_id)
  rescue
    ArgumentError -> Pack.player_character!("crossroads_ledger")
  end

  defp relationships(_runtime, nil), do: %{}

  defp relationships(runtime, pc_slug),
    do: %{pc_slug => Map.get(runtime, "relationship_score", 0.0)}

  defp opt(opts, key), do: Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
end
