defmodule TalesForge.Playtest.CharacterChanges do
  @moduledoc """
  How the player character and the GM's characters (NPCs) changed over a
  playtest run: start versus end per character, and a per-turn timeline. Admin
  and playtest reports only; read-only.

  ## Where it reads from

  There are no per-turn snapshots of characters today, so the changes are
  derived from the state that is stored (every read goes through this module):

    * **NPC start**: the authored definition copied into
      `npc_instances.personality` (mood, home location, current concern) and
      the seed defaults of `TalesForge.NPC` (relationship 0.0, no memories).
    * **NPC end**: `npc_instances.runtime_state` (mood, location,
      `relationship_score`, current concern, the newest 20 memories) and the
      latest Jev reaction per NPC in `game_sessions.world_state["npc_moods"]`.
    * **Memories**: `npc_instances.runtime_state["memories"]` joined with
      `character_memories` (every memory mirrored by `TalesForge.Characters`),
      placed on a turn by world tick (the `gm_reasoning` session event of each
      turn records its tick), else by timestamp. Who wrote a memory is told
      from its text and from the GM's `npc_memory_updates` in the same
      `gm_reasoning` event.
    * **Player character**: the sheet copied into `characters.definition` at
      creation (start) and `world_state["character"]` (end); travel from
      `player.travel` session events; learning points and improvement rolls
      from each turn's `mechanical_resolution`.
    * **Levers**: OCEAN, Maslow level and concerns from the `characters` rows.
      They are written once and never updated during play, so their changes
      are reported as not tracked yet.
    * **Reaction calls**: `ai_calls` rows with purpose `npc_reaction` say a
      reaction was read on a turn, not what it was.

  What cannot be reconstructed is said, not guessed: fields come back with
  status `:not_tracked`, and `notes` lists the gaps of the run.

  ## Later

  Once the world event log of the stateful-world design (`WORLD_STATE`) lands,
  this module is the one place to switch: read the per-entity events and
  snapshots instead of the scattered state above, and keep the structs.
  """

  import Ecto.Query

  alias TalesForge.Game.Pack

  alias TalesForge.Playtest.CharacterChanges.{
    Change,
    Character,
    Field,
    Memory,
    RunMetrics,
    Summary,
    TurnEntry
  }

  alias TalesForge.Repo

  alias TalesForge.Schemas.{
    AICall,
    CharacterMemory,
    GameSession,
    NpcInstance,
    PlaytestRun,
    SessionEvent,
    Turn
  }

  alias TalesForge.Schemas.Character, as: CharacterRow

  @typedoc """
  A run's character changes: the characters (player character first) with
  their start-versus-end rows and memories, the per-turn timeline (turns with
  changes only, oldest first; a last entry with `turn_number: nil` holds
  changes whose turn cannot be told), whether the run had Jev NPC reactions,
  and the notes on what this run's stored state cannot tell.
  """
  @type t :: %__MODULE__{
          session_id: String.t(),
          characters: [Character.t()],
          timeline: [TurnEntry.t()],
          reactions_tracked?: boolean(),
          notes: [String.t()]
        }

  @enforce_keys [:session_id]
  defstruct [:session_id, characters: [], timeline: [], reactions_tracked?: false, notes: []]

  @typedoc """
  The stored state of one session, as loaded by `for_sessions/1`; plain maps
  with string keys where the database holds JSON. `build/1` turns it into `t()`.
  """
  @type sources :: %{
          session_id: String.t(),
          world: map(),
          npcs: [map()],
          characters: [map()],
          memories: [map()],
          gm_turns: [map()],
          travel: [map()],
          turns: [map()],
          reaction_calls: [map()]
        }

  @not_yet "not tracked yet"
  @lever_note "Set once when the character is written; nothing updates it during play yet."
  @ocean_note "Memories are stored as written: no OCEAN filter keeps or drops memories yet, " <>
                "so nothing can be shown as kept or dropped. The traits are fixed for the session."
  @denominations ~w(platinum gold silver copper)

  # --- loading ----------------------------------------------------------------

  @doc """
  The character changes of one game session. A session id that does not exist
  gives an empty result (no characters, no timeline).
  """
  @spec for_session(String.t()) :: t()
  def for_session(session_id) when is_binary(session_id),
    do: session_id |> List.wrap() |> for_sessions() |> Map.fetch!(session_id)

  @doc """
  The character changes of several sessions at once, keyed by session id, in a
  fixed number of queries (for batch summaries). Every id given gets an entry.
  """
  @spec for_sessions([String.t()]) :: %{String.t() => t()}
  def for_sessions([]), do: %{}

  def for_sessions(session_ids) when is_list(session_ids) do
    ids = Enum.uniq(session_ids)
    worlds = load_worlds(ids)
    npcs = ids |> load_npcs() |> Enum.group_by(& &1.session_id)
    characters = ids |> load_characters() |> Enum.group_by(& &1.session_id)
    memories = ids |> load_memories() |> Enum.group_by(& &1.session_id)
    gm_turns = ids |> load_gm_turns() |> Enum.group_by(& &1.session_id)
    travel = ids |> load_travel() |> Enum.group_by(& &1.session_id)
    turns = ids |> load_turns() |> Enum.group_by(& &1.session_id)
    calls = ids |> load_reaction_calls() |> Enum.group_by(& &1.session_id)

    Map.new(ids, fn id ->
      {id,
       build(%{
         session_id: id,
         world: Map.get(worlds, id, %{}),
         npcs: Map.get(npcs, id, []),
         characters: Map.get(characters, id, []),
         memories: Map.get(memories, id, []),
         gm_turns: Map.get(gm_turns, id, []),
         travel: Map.get(travel, id, []),
         turns: Map.get(turns, id, []),
         reaction_calls: Map.get(calls, id, [])
       })}
    end)
  end

  defp load_worlds(ids) do
    from(g in GameSession,
      where: g.id in ^ids,
      select:
        {g.id,
         %{
           "npc_moods" => fragment("?->'npc_moods'", g.world_state),
           "character" => fragment("?->'character'", g.world_state),
           "location_id" => fragment("?->>'location_id'", g.world_state)
         }}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp load_npcs(ids) do
    from(n in NpcInstance,
      where: n.game_session_id in ^ids,
      order_by: n.npc_id,
      select: %{
        session_id: n.game_session_id,
        npc_id: n.npc_id,
        name: fragment("?->>'name'", n.personality),
        default_location_id: fragment("?->>'default_location_id'", n.personality),
        start_mood: fragment("?->'motivations'->>'mood'", n.personality),
        start_concern: fragment("?->'motivations'->'current_concern'", n.personality),
        runtime: n.runtime_state
      }
    )
    |> Repo.all()
  end

  defp load_characters(ids) do
    from(c in CharacterRow,
      where: c.game_session_id in ^ids,
      select: %{
        session_id: c.game_session_id,
        slug: c.slug,
        controller: c.controller,
        name: c.name,
        maslow_level: c.maslow_level,
        concerns: c.concerns,
        ocean: c.ocean,
        definition: fragment("CASE WHEN ? <> 'gm' THEN ? END", c.controller, c.definition)
      }
    )
    |> Repo.all()
    |> Enum.map(fn c ->
      %{
        c
        | concerns: Enum.map(c.concerns || [], &Map.take(&1, [:text, :priority])),
          ocean: c.ocean && Map.from_struct(c.ocean)
      }
    end)
  end

  defp load_memories(ids) do
    from(m in CharacterMemory,
      join: c in CharacterRow,
      on: c.id == m.character_id,
      where: c.game_session_id in ^ids,
      order_by: [m.tick, m.inserted_at],
      select: %{
        session_id: c.game_session_id,
        slug: c.slug,
        tick: m.tick,
        text: m.text,
        felt: m.felt,
        inserted_at: m.inserted_at
      }
    )
    |> Repo.all()
  end

  defp load_gm_turns(ids) do
    from(e in SessionEvent,
      where: e.game_session_id in ^ids and e.kind == "gm_reasoning",
      select: %{
        session_id: e.game_session_id,
        tick: e.tick,
        turn_number: fragment("(?->>'turn_number')::int", e.payload),
        updates: fragment("?->'gm_reply'->'npc_memory_updates'", e.payload)
      }
    )
    |> Repo.all()
  end

  defp load_travel(ids) do
    from(e in SessionEvent,
      where: e.game_session_id in ^ids and e.kind == "player.travel",
      order_by: [e.tick, e.inserted_at],
      select: %{
        session_id: e.game_session_id,
        tick: e.tick,
        from: fragment("?->>'from'", e.payload),
        to: fragment("?->>'to'", e.payload)
      }
    )
    |> Repo.all()
  end

  defp load_turns(ids) do
    from(t in Turn,
      where: t.game_session_id in ^ids,
      order_by: t.turn_number,
      select: %{
        session_id: t.game_session_id,
        id: t.id,
        turn_number: t.turn_number,
        inserted_at: t.inserted_at,
        lp_awarded: fragment("?->'lp_awarded'", t.mechanical_resolution),
        lp_skill: fragment("?->>'skill'", t.mechanical_resolution),
        improvements: fragment("?->'improvements'", t.mechanical_resolution)
      }
    )
    |> Repo.all()
  end

  defp load_reaction_calls(ids) do
    from(c in AICall,
      where: c.game_session_id in ^ids and c.purpose == "npc_reaction",
      group_by: [c.game_session_id, c.turn_number, c.status],
      select: %{
        session_id: c.game_session_id,
        turn_number: c.turn_number,
        status: c.status,
        count: count(c.id)
      }
    )
    |> Repo.all()
  end

  # --- building ---------------------------------------------------------------

  @doc """
  Builds a run's character changes from its loaded state (`sources()`). Pure:
  `for_sessions/1` loads the state and calls this; tests can call it with
  plain maps.
  """
  @spec build(sources()) :: t()
  def build(%{session_id: session_id} = src) do
    turns = turn_index(src.turns, src.gm_turns)
    moods = src.world["npc_moods"] || %{}
    tracked? = moods != %{} or src.reaction_calls != []
    rows = Map.new(src.characters, &{&1.slug, &1})
    gm_updates = gm_update_set(src.gm_turns)
    stored = Enum.group_by(src.memories, & &1.slug)
    pc = build_pc(src, rows, turns)

    npcs =
      Enum.map(src.npcs, fn npc ->
        memories =
          npc.runtime
          |> runtime_memories()
          |> merge_memories(Map.get(stored, npc.npc_id, []))
          |> Enum.map(&to_memory(&1, npc.npc_id, gm_updates, turns))
          # Stable: within a turn, the order they were written in.
          |> Enum.sort_by(&(&1.turn_number || :unknown))

        build_npc(npc, Map.get(rows, npc.npc_id), Map.get(moods, npc.npc_id), tracked?, memories)
      end)
      |> Enum.sort_by(&{not &1.changed?, -length(&1.memories_added), &1.name})

    characters = List.wrap(pc) ++ npcs

    %__MODULE__{
      session_id: session_id,
      characters: characters,
      timeline: timeline(characters, src, moods, turns),
      reactions_tracked?: tracked?,
      notes: notes(src, tracked?, turns)
    }
  end

  # Turns with their world tick (from the turn's gm_reasoning event, nil when
  # missing), oldest first.
  defp turn_index(turns, gm_turns) do
    ticks = Map.new(gm_turns, &{&1.turn_number, &1.tick})

    turns
    |> Enum.sort_by(& &1.turn_number)
    |> Enum.map(&Map.put(&1, :tick, Map.get(ticks, &1.turn_number)))
  end

  defp gm_update_set(gm_turns) do
    for %{updates: updates} <- gm_turns,
        %{} = u <- List.wrap(updates),
        is_binary(u["npc_id"]) and is_binary(u["summary"]),
        into: MapSet.new(),
        do: {u["npc_id"], String.trim(u["summary"])}
  end

  defp runtime_memories(runtime) do
    for %{} = m <- List.wrap((runtime || %{})["memories"]),
        text = memory_text(m),
        is_binary(text),
        do: %{
          tick: int_or_nil(m["tick"]),
          text: text,
          felt: m["felt"],
          at: parse_time(m["at"]),
          world?: Map.has_key?(m, "who") or Map.has_key?(m, "felt"),
          inserted_at: nil
        }
  end

  defp memory_text(m) do
    case m["summary"] || m["what"] do
      text when is_binary(text) and text != "" -> String.trim(text)
      _ -> nil
    end
  end

  # Runtime memories (the newest 20, in the order written) plus mirrored rows
  # not among them, deduped on tick + text like the mirror itself.
  defp merge_memories(runtime, stored) do
    mirrored = Map.new(stored, &{{&1.tick, &1.text}, &1})

    from_runtime =
      Enum.map(runtime, fn m ->
        case Map.get(mirrored, {m.tick, m.text}) do
          nil -> m
          row -> %{m | inserted_at: row.inserted_at, felt: m.felt || row.felt}
        end
      end)

    seen = MapSet.new(from_runtime, &{&1.tick, &1.text})

    only_stored =
      for row <- stored,
          not MapSet.member?(seen, {row.tick, row.text}),
          do: %{
            tick: row.tick,
            text: row.text,
            felt: row.felt,
            at: nil,
            world?: is_binary(row.felt),
            inserted_at: row.inserted_at
          }

    Enum.uniq_by(only_stored ++ from_runtime, &{&1.tick, &1.text})
  end

  defp to_memory(m, npc_id, gm_updates, turns) do
    %Memory{
      turn_number: turn_for(m, turns),
      tick: m.tick,
      text: m.text,
      felt: m.felt,
      source: memory_source(m, npc_id, gm_updates)
    }
  end

  defp memory_source(%{text: "Player spoke to me:" <> _}, _npc_id, _gm), do: :heard
  defp memory_source(%{text: "Overheard " <> _}, _npc_id, _gm), do: :overheard

  defp memory_source(m, npc_id, gm_updates) do
    cond do
      MapSet.member?(gm_updates, {npc_id, m.text}) -> :gm
      m.world? -> :world
      true -> :unknown
    end
  end

  # The turn a memory or event belongs to: by world tick (each turn's tick is
  # the tick after it), else by when it was written.
  defp turn_for(%{tick: tick} = item, turns) when is_integer(tick) do
    case Enum.find(turns, &(is_integer(&1.tick) and &1.tick >= tick)) do
      nil -> turn_by_time(item, turns)
      turn -> turn.turn_number
    end
  end

  defp turn_for(item, turns), do: turn_by_time(item, turns)

  defp turn_by_time(item, turns) do
    case Map.get(item, :at) || Map.get(item, :inserted_at) do
      %DateTime{} = at ->
        turns
        |> Enum.filter(&(DateTime.compare(&1.inserted_at, at) != :gt))
        |> List.last()
        |> case do
          nil -> nil
          turn -> turn.turn_number
        end

      _ ->
        nil
    end
  end

  # --- NPCs -------------------------------------------------------------------

  defp build_npc(npc, row, reaction, tracked?, memories) do
    runtime = npc.runtime || %{}
    name = npc.name || (row && row.name) || npc.npc_id

    fields =
      [
        field(:location, "Location", "npc_instances (home in the definition → runtime)",
          start: npc.default_location_id,
          end: runtime["location_id"]
        ),
        field(:mood, "Mood", "npc_instances (definition mood → runtime mood)",
          start: npc.start_mood || "neutral",
          end: runtime["mood"]
        ),
        stance_field(reaction, tracked?),
        feeling_field(reaction, tracked?),
        relationship_field(runtime),
        concern_field(npc.start_concern, runtime["current_concern"]),
        memories_field(memories)
      ]
      |> Enum.reject(&is_nil/1)

    not_tracked =
      [
        %Field{
          key: :toward_npcs,
          label: "Feelings toward other NPCs",
          status: :not_tracked,
          source: "none",
          note:
            "Feelings point only at the player character (one relationship score, one Jev stance)."
        }
      ] ++ lever_rows(row)

    changed? = Enum.any?(fields, &(&1.status == :changed)) or memories != []

    %Character{
      slug: npc.npc_id,
      name: name,
      kind: :npc,
      controller: "gm",
      fields: fields,
      not_tracked: not_tracked,
      memories_added: memories,
      changed?: changed?
    }
  end

  defp stance_field(_reaction, false),
    do: %Field{
      key: :stance,
      label: "Stance toward the player character",
      status: :not_tracked,
      source: "world_state npc_moods (Jev reactions)",
      note: "No Jev NPC reactions in this run (NPC_REACTIONS off)."
    }

  defp stance_field(reaction, true) do
    stance = reaction && reaction["stance"]

    %Field{
      key: :stance,
      label: "Stance toward the player character",
      start_value: "neutral (no reaction yet)",
      end_value: if(stance, do: "#{stance} (turn #{reaction["turn_number"]})", else: "neutral"),
      status: if(stance && stance != "neutral", do: :changed, else: :unchanged),
      source: "world_state npc_moods (latest Jev reaction)",
      note: if(is_nil(stance), do: "No reaction read: never on stage on a turn.")
    }
  end

  defp feeling_field(_reaction, false), do: nil
  defp feeling_field(nil, true), do: nil

  defp feeling_field(reaction, true),
    do: %Field{
      key: :feeling,
      label: "Feeling (latest reaction)",
      start_value: "none",
      end_value: reaction_text(reaction),
      status: :changed,
      source: "world_state npc_moods (latest Jev reaction)",
      note: "Only the latest reaction is kept; earlier ones are not stored."
    }

  defp relationship_field(runtime) do
    score = number_or_nil(runtime["relationship_score"])

    if score do
      %Field{
        key: :relationship,
        label: "Relationship score toward the player character",
        start_value: "0.00",
        end_value: fmt_number(score),
        status: if(abs(score) > 1.0e-9, do: :changed, else: :unchanged),
        source: "npc_instances runtime relationship_score (NPC agent, when spoken to)"
      }
    end
  end

  defp concern_field(nil, nil), do: nil

  defp concern_field(start, current),
    do:
      field(:concern, "Current concern", "npc_instances (definition → runtime current_concern)",
        start: concern_text(start),
        end: concern_text(current)
      )

  defp memories_field(memories),
    do: %Field{
      key: :memories,
      label: "Memories",
      start_value: "0",
      end_value: "#{length(memories)}",
      status: if(memories == [], do: :unchanged, else: :changed),
      source: "npc_instances runtime memories + character_memories",
      note: "NPCs start a session with no memories."
    }

  # --- player character -------------------------------------------------------

  defp build_pc(src, rows, turns) do
    row = Enum.find(src.characters, &(&1.controller != "gm"))
    sheet = src.world["character"]

    if row || is_map(sheet) do
      sheet = sheet || %{}
      start = if row && is_map(row.definition), do: Pack.sheet(row.definition)
      slug = (row && row.slug) || sheet["id"] || "player"

      fields =
        [
          pc_location(src.travel, src.world["location_id"] || sheet["location_id"]),
          start && condition_field(start, sheet),
          start && coins_field(start, sheet),
          start && lp_field(start, sheet),
          start && skills_field(start, sheet)
        ]
        |> Enum.reject(&is_nil/1)

      not_tracked =
        [
          %Field{
            key: :memories,
            label: "Memories",
            status: :not_tracked,
            source: "none",
            note: "The player character has no memory store yet; only NPCs keep memories."
          },
          %Field{
            key: :toward_npcs,
            label: "Feelings toward NPCs",
            status: :not_tracked,
            source: "none",
            note: "Nothing records how the player character feels about anyone."
          },
          %Field{
            key: :mood,
            label: "Mood",
            status: :not_tracked,
            source: "none",
            note: "The player character has no mood field."
          }
        ] ++ lever_rows(Map.get(rows, slug, row))

      %Character{
        slug: slug,
        name: sheet["name"] || (row && row.name) || slug,
        kind: :pc,
        controller: row && row.controller,
        fields: fields,
        not_tracked:
          if(start,
            do: not_tracked,
            else: not_tracked ++ [no_start_row()]
          ),
        memories_added: [],
        changed?: Enum.any?(fields, &(&1.status == :changed)) or pc_learned?(turns)
      }
    end
  end

  defp no_start_row,
    do: %Field{
      key: :sheet,
      label: "Sheet at the start",
      status: :not_tracked,
      source: "characters.definition",
      note: "No characters row with the starting sheet for this session."
    }

  defp pc_learned?(turns),
    do: Enum.any?(turns, &(learning_text(&1) != nil))

  defp pc_location(travel, end_location) do
    start =
      case travel do
        [first | _] -> first.from
        [] -> end_location
      end

    field(:location, "Location", "player.travel session events, world_state location_id",
      start: start,
      end: end_location
    )
  end

  defp condition_field(start, sheet),
    do:
      field(:condition, "Wounds and vitality", "characters.definition → world_state character",
        start: condition_text(start),
        end: condition_text(sheet)
      )

  defp coins_field(start, sheet),
    do:
      field(:coins, "Coins", "characters.definition → world_state character",
        start: coins_text(start["coins"]),
        end: coins_text(sheet["coins"])
      )

  defp lp_field(start, sheet),
    do:
      field(:learning_points, "Learning points", "characters.definition → world_state character",
        start: lp_text(start["learning_points"]),
        end: lp_text(sheet["learning_points"])
      )

  defp skills_field(start, sheet) do
    before = int_map(start["skills"])
    now = int_map(sheet["skills"])
    changed = for {k, v} <- now, Map.get(before, k) != v, do: k

    if changed == [] do
      %Field{
        key: :skills,
        label: "Skills",
        start_value: "#{map_size(now)} skills",
        end_value: "#{map_size(now)} skills",
        status: :unchanged,
        source: "characters.definition → world_state character"
      }
    else
      keys = Enum.sort(changed)

      %Field{
        key: :skills,
        label: "Skills",
        start_value: Enum.map_join(keys, ", ", &"#{&1} #{Map.get(before, &1, "none")}"),
        end_value: Enum.map_join(keys, ", ", &"#{&1} #{Map.get(now, &1)}"),
        status: :changed,
        source: "characters.definition → world_state character"
      }
    end
  end

  # --- levers -----------------------------------------------------------------

  defp lever_rows(nil),
    do: [
      %Field{
        key: :levers,
        label: "OCEAN, Maslow level and concerns",
        status: :not_tracked,
        source: "characters",
        note: "No characters row for this character in this session."
      }
    ]

  defp lever_rows(row),
    do: [
      %Field{
        key: :maslow,
        label: "Maslow level",
        start_value: row.maslow_level,
        status: :not_tracked,
        source: "characters.maslow_level",
        note: @lever_note
      },
      %Field{
        key: :concerns,
        label: "Concerns",
        start_value: concerns_text(row.concerns),
        status: :not_tracked,
        source: "characters.concerns",
        note: @lever_note
      },
      %Field{
        key: :ocean_memory,
        label: "Personality-filtered memory (OCEAN)",
        start_value: ocean_text(row.ocean),
        status: :not_tracked,
        source: "characters.ocean",
        note: @ocean_note
      }
    ]

  # --- timeline ---------------------------------------------------------------

  defp timeline(characters, src, moods, turns) do
    pc = Enum.find(characters, &(&1.kind == :pc))
    names = Map.new(characters, &{&1.slug, &1.name})

    memory_changes =
      for c <- characters, m <- c.memories_added do
        {m.turn_number,
         %Change{
           slug: c.slug,
           name: c.name,
           kind: :memory,
           text: "#{source_label(m.source)}: #{m.text}"
         }}
      end

    pc_changes = if pc, do: pc_changes(pc, src.travel, turns), else: []

    reaction_changes =
      for {npc_id, %{"turn_number" => n} = r} <- moods, is_integer(n) do
        name = Map.get(names, npc_id, npc_id)

        {n,
         %Change{
           slug: npc_id,
           name: name,
           kind: :reaction,
           text: "latest kept reaction: #{reaction_text(r)}"
         }}
      end

    call_changes =
      src.reaction_calls
      |> Enum.group_by(& &1.turn_number)
      |> Enum.map(fn {n, rows} -> {n, reaction_calls_change(rows)} end)

    ids = Map.new(turns, &{&1.turn_number, &1.id})

    (memory_changes ++ pc_changes ++ call_changes ++ reaction_changes)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {n, changes} ->
      %TurnEntry{turn_number: n, turn_id: Map.get(ids, n), changes: changes}
    end)
    |> Enum.sort_by(&(&1.turn_number || :unknown))
  end

  defp pc_changes(pc, travel, turns) do
    moves =
      for t <- travel do
        {turn_for(t, turns),
         %Change{slug: pc.slug, name: pc.name, kind: :travel, text: "#{t.from} → #{t.to}"}}
      end

    learning =
      for t <- turns, text = learning_text(t), text != nil do
        {t.turn_number, %Change{slug: pc.slug, name: pc.name, kind: :learning, text: text}}
      end

    moves ++ learning
  end

  defp learning_text(turn) do
    lp =
      case number_or_nil(turn.lp_awarded) do
        n when is_number(n) and n > 0 -> "+#{fmt_number(n)} LP#{skill_suffix(turn.lp_skill)}"
        _ -> nil
      end

    rolls =
      for %{"skill" => skill} = i <- List.wrap(turn.improvements) do
        if i["improved"], do: "#{skill} improved", else: "#{skill} improvement roll failed"
      end

    case Enum.reject([lp | rolls], &is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

  defp skill_suffix(nil), do: ""
  defp skill_suffix(skill), do: " (#{skill})"

  defp reaction_calls_change(rows) do
    ok = rows |> Enum.filter(&(&1.status == "ok")) |> Enum.map(& &1.count) |> Enum.sum()
    failed = rows |> Enum.reject(&(&1.status == "ok")) |> Enum.map(& &1.count) |> Enum.sum()
    failed_text = if failed > 0, do: ", #{failed} failed", else: ""

    %Change{
      slug: "npc_reactions",
      name: "NPC reactions",
      kind: :reaction,
      text: "Jev read #{ok} reaction(s)#{failed_text}; the values are not stored per turn"
    }
  end

  @doc "A short label for who wrote a memory."
  @spec source_label(Memory.source()) :: String.t()
  def source_label(:gm), do: "GM"
  def source_label(:heard), do: "heard the player"
  def source_label(:overheard), do: "overheard"
  def source_label(:world), do: "world move"
  def source_label(:unknown), do: "source unknown"

  # --- notes ------------------------------------------------------------------

  defp notes(src, tracked?, turns) do
    missing_ticks = Enum.count(turns, &is_nil(&1.tick))

    [
      tracked? &&
        "Jev NPC reactions: only each NPC's latest reaction is kept (world_state npc_moods); " <>
          "earlier ones are not stored, and ai_calls rows show that a reaction was read, not what it was.",
      "NPC mood, relationship score, location and current concern: npc_instances keeps only " <>
        "the current value, so the start comes from the authored definition and the steps in between " <>
        "cannot be told.",
      "Player character wounds, coins and learning points: start and end only; turn records keep " <>
        "the roll, LP awarded and improvement rolls, not the sheet.",
      "NPC memories: the newest 20 per NPC (npc_instances) joined with every memory mirrored into " <>
        "character_memories; a memory that fell out of the newest 20 before the next mirror is lost.",
      missing_ticks > 0 &&
        "#{missing_ticks} turn(s) have no gm_reasoning event, so their memories are placed by timestamp.",
      src.characters == [] &&
        "No characters rows for this session: OCEAN, Maslow level and concerns are not available."
    ]
    |> Enum.filter(&is_binary/1)
  end

  # --- batch metrics ----------------------------------------------------------

  @doc """
  The per-run numbers behind the batch summary (`RunMetrics`): memories added,
  NPCs with any change, and whether (and for how many NPCs) an NPC's attitude
  toward the player character changed (Jev stance off neutral, or relationship
  score off 0.0).
  """
  @spec run_metrics(t()) :: RunMetrics.t()
  def run_metrics(%__MODULE__{} = changes) do
    npcs = Enum.filter(changes.characters, &(&1.kind == :npc))
    attitude = Enum.filter(npcs, &attitude_changed?/1)
    stance? = Enum.any?(npcs, &field_changed?(&1, :stance))
    relationship? = Enum.any?(npcs, &field_changed?(&1, :relationship))

    %RunMetrics{
      memories_added: changes.characters |> Enum.map(&length(&1.memories_added)) |> Enum.sum(),
      npcs_changed: Enum.count(npcs, & &1.changed?),
      npcs_attitude_changed: length(attitude),
      stance_changed?: stance?,
      relationship_changed?: relationship?,
      attitude_changed?: stance? or relationship?,
      reactions_tracked?: changes.reactions_tracked?
    }
  end

  defp attitude_changed?(npc),
    do: field_changed?(npc, :stance) or field_changed?(npc, :relationship)

  defp field_changed?(character, key),
    do: Enum.any?(character.fields, &(&1.key == key and &1.status == :changed))

  @doc """
  Summarises a batch of runs (`t()` or `RunMetrics`): the share of runs where
  an NPC's attitude toward the player character changed, NPCs whose attitude
  changed per run, memories added per run and NPCs with any change per run
  (median and mean).

      iex> alias TalesForge.Playtest.CharacterChanges.RunMetrics
      iex> s = TalesForge.Playtest.CharacterChanges.summarize([
      ...>   %RunMetrics{memories_added: 4, npcs_changed: 2, attitude_changed?: true, stance_changed?: true},
      ...>   %RunMetrics{memories_added: 0, npcs_changed: 0}
      ...> ])
      iex> {s.runs, s.attitude_changed_share, s.memories_median, s.npcs_changed_mean}
      {2, 0.5, 2.0, 1.0}
  """
  @spec summarize([t() | RunMetrics.t()]) :: Summary.t()
  def summarize(runs) when is_list(runs) do
    metrics = Enum.map(runs, &to_metrics/1)
    n = length(metrics)
    attitude = Enum.count(metrics, & &1.attitude_changed?)
    memories = Enum.map(metrics, & &1.memories_added)
    npcs = Enum.map(metrics, & &1.npcs_changed)
    attitude_npcs = Enum.map(metrics, & &1.npcs_attitude_changed)

    %Summary{
      runs: n,
      attitude_changed: attitude,
      attitude_changed_share: if(n > 0, do: attitude / n),
      stance_changed: Enum.count(metrics, & &1.stance_changed?),
      relationship_changed: Enum.count(metrics, & &1.relationship_changed?),
      reaction_runs: Enum.count(metrics, & &1.reactions_tracked?),
      memories_median: median(memories),
      memories_mean: mean(memories),
      npcs_changed_median: median(npcs),
      npcs_changed_mean: mean(npcs),
      attitude_npcs_median: median(attitude_npcs),
      attitude_npcs_mean: mean(attitude_npcs)
    }
  end

  defp to_metrics(%RunMetrics{} = m), do: m
  defp to_metrics(%__MODULE__{} = changes), do: run_metrics(changes)

  @doc """
  Character-change summaries of playtest runs grouped by batch: the series tag
  in the notes (`series=NAME variant=V`, see `TalesForge.Playtest.Series`)
  makes the label `"NAME · V"`; other runs are `"not in a series"`. Running
  runs and runs without a played turn are left out. Batches come newest first.
  """
  @spec batches([PlaytestRun.t()]) :: [
          %{label: String.t(), summary: Summary.t(), last_started_at: DateTime.t() | nil}
        ]
  def batches(runs) when is_list(runs) do
    runs = Enum.filter(runs, &(&1.status != "running" and (&1.turns_played || 0) > 0))
    changes = runs |> Enum.map(& &1.game_session_id) |> for_sessions()

    runs
    |> Enum.group_by(&batch_label(&1.notes))
    |> Enum.map(fn {label, group} ->
      %{
        label: label,
        summary: group |> Enum.map(&Map.fetch!(changes, &1.game_session_id)) |> summarize(),
        last_started_at: group |> Enum.map(& &1.started_at) |> Enum.max(DateTime, fn -> nil end)
      }
    end)
    |> Enum.sort_by(&(&1.last_started_at && DateTime.to_unix(&1.last_started_at)), :desc)
  end

  @doc """
  The batch label of a run's notes.

      iex> TalesForge.Playtest.CharacterChanges.batch_label("series=ab-1 variant=default · retry")
      "ab-1 · default"
      iex> TalesForge.Playtest.CharacterChanges.batch_label("started from admin")
      "not in a series"
  """
  @spec batch_label(String.t() | nil) :: String.t()
  def batch_label(notes) when is_binary(notes) do
    case Regex.run(~r/\Aseries=(\S+) variant=(\S+)/, notes) do
      [_, name, variant] -> "#{name} · #{variant}"
      _ -> "not in a series"
    end
  end

  def batch_label(_notes), do: "not in a series"

  @doc """
  The summary of one series per variant, for the rpc console next to
  `TalesForge.Playtest.Series.progress/1`:

      bin/ex_tales_forge rpc 'TalesForge.Playtest.CharacterChanges.series_summary("jev-ab-1") |> IO.inspect()'
  """
  @spec series_summary(String.t()) :: %{String.t() => Summary.t()}
  def series_summary(name) when is_binary(name) do
    prefix = String.replace("series=#{name} variant=", ~w(\\ % _), &"\\#{&1}")

    from(r in PlaytestRun, where: like(r.notes, ^"#{prefix}%"))
    |> Repo.all()
    |> batches()
    |> Map.new(fn %{label: label, summary: s} ->
      {label |> String.split(" · ") |> List.last(), s}
    end)
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid) / 1,
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)

  # --- formatting -------------------------------------------------------------

  defp field(key, label, source, values) do
    start = Keyword.fetch!(values, :start)
    finish = Keyword.fetch!(values, :end)

    %Field{
      key: key,
      label: label,
      start_value: start,
      end_value: finish,
      status: if(start == finish, do: :unchanged, else: :changed),
      source: source,
      note: if(is_nil(start) and is_nil(finish), do: @not_yet)
    }
  end

  defp reaction_text(r) do
    [
      r["emotion"] && "#{r["emotion"]} (#{fmt_number(r["intensity"])})",
      r["stance"] && "stance #{r["stance"]}",
      r["turn_number"] && "turn #{r["turn_number"]}",
      r["confidence"] && "confidence #{fmt_number(r["confidence"])}"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(", ")
  end

  defp concern_text(%{"focus" => focus} = c) when is_binary(focus) do
    case c["priority"] do
      p when is_integer(p) -> "#{focus} (priority #{p})"
      _ -> focus
    end
  end

  defp concern_text(_), do: nil

  defp concerns_text([]), do: "none"

  defp concerns_text(concerns),
    do: Enum.map_join(concerns, "; ", &"#{&1.text} (priority #{&1.priority})")

  defp ocean_text(nil), do: nil

  defp ocean_text(ocean) do
    ~w(openness conscientiousness extraversion agreeableness neuroticism)a
    |> Enum.map_join(" ", fn trait ->
      "#{trait |> Atom.to_string() |> String.first() |> String.upcase()}#{Map.get(ocean, trait)}"
    end)
  end

  defp condition_text(sheet) do
    wounds = int_or_nil(sheet["wounds"]) || 0
    max = int_or_nil(sheet["wound_max"]) || 3
    "#{wounds}/#{max} wounds, #{sheet["vitality"] || "ok"}"
  end

  defp coins_text(coins) when is_map(coins) do
    known = Enum.filter(@denominations, &(int_or_nil(coins[&1]) not in [nil, 0]))
    others = coins |> Map.keys() |> Enum.reject(&(&1 in @denominations)) |> Enum.sort()

    case Enum.map(known ++ others, &"#{coins[&1]} #{&1}") do
      [] -> "none"
      parts -> Enum.join(parts, ", ")
    end
  end

  defp coins_text(_), do: "none"

  defp lp_text(lp) when is_map(lp) and map_size(lp) > 0 do
    lp
    |> Enum.filter(fn {_k, v} -> is_number(v) and v != 0 end)
    |> Enum.sort()
    |> case do
      [] -> "none"
      pairs -> Enum.map_join(pairs, ", ", fn {k, v} -> "#{k} #{fmt_number(v)}" end)
    end
  end

  defp lp_text(_), do: "none"

  defp int_map(map) when is_map(map),
    do: for({k, v} <- map, is_number(v), into: %{}, do: {to_string(k), trunc(v)})

  defp int_map(_), do: %{}

  defp fmt_number(n) when is_integer(n), do: Integer.to_string(n)
  defp fmt_number(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp fmt_number(_), do: "?"

  defp number_or_nil(n) when is_number(n), do: n
  defp number_or_nil(_), do: nil

  defp int_or_nil(n) when is_integer(n), do: n
  defp int_or_nil(n) when is_float(n), do: trunc(n)
  defp int_or_nil(_), do: nil

  defp parse_time(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_time(_), do: nil
end
