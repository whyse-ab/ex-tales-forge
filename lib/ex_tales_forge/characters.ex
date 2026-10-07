defmodule TalesForge.Characters do
  @moduledoc """
  One Character entity for player characters and NPCs (phase 1 of the
  Character plan in tales-forge-docs: setup only).

  `seed_session/2` writes a `characters` row for the player character and for
  every NPC when a session is created. Nothing reads these rows yet: the game
  still runs on `world_state["character"]` and `npc_instances`, so prompts and
  play are unchanged. Per-turn changes are not mirrored yet (later phase).
  """

  import Ecto.Query

  alias TalesForge.Characters.Levers
  alias TalesForge.Game.Pack
  alias TalesForge.Game.WorldClock
  alias TalesForge.NPC
  alias TalesForge.Repo
  alias TalesForge.Schemas.{Character, CharacterMemory, GameSession, NpcInstance}

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

  @doc """
  Writes the session's characters: the player character (from
  `world_state["character"]` plus the pack file's levers) and one per NPC
  instance. Idempotent: an existing slug is left alone.

  Options (atom or string keys):
    * `:controller` – `"player"` (default) or `"bot"` for the persona runner
    * `:controller_ref` – who controls the player character (a persona id, …)
    * `:owner_player_id` – the player the character belongs to (nil for now)
  """
  def seed_session(%GameSession{} = session, opts \\ %{}) do
    tick = Map.get(session.world_state, "world_tick", WorldClock.default_start_tick())
    pc = player_character_attrs(session, opts, tick)
    pc_slug = pc.slug

    npcs =
      session.id
      |> NPC.list_instances()
      |> Enum.map(&from_npc_instance(&1, tick, pc_slug))

    result =
      Repo.transaction(fn ->
        Enum.each([pc | npcs], &insert_or_rollback!(&1, session.id))
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, {:characters, reason}}
    end
  end

  defp insert_or_rollback!(attrs, session_id) do
    changeset = Character.changeset(%Character{}, Map.put(attrs, :game_session_id, session_id))

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:game_session_id, :slug]) do
      {:ok, _} -> :ok
      {:error, changeset} -> Repo.rollback({attrs.slug, changeset})
    end
  end

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
  def player_character_attrs(%GameSession{world_state: world_state}, opts, tick) do
    adventure_id = Map.get(world_state, "adventure_id", "crossroads_ledger")
    file = Pack.player_character!(adventure_id)
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
      skills: sheet["skills"] || %{},
      ocean: Levers.ocean_source(file),
      maslow_level: file["maslow"],
      maslow_since_tick: tick,
      concerns: concerns(file["concerns"], tick),
      inventory: sheet["inventory"] || [],
      coins: sheet["coins"] || %{},
      wounds: sheet["wounds"] || 0,
      wound_max: sheet["wound_max"] || 3,
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
  def from_npc_instance(%NpcInstance{} = inst, tick, pc_slug \\ nil) do
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
      skills: definition["skills"] || %{},
      ocean: Levers.ocean_source(definition),
      maslow_level: maslow_level(definition),
      maslow_since_tick: tick,
      concerns: concerns(definition["concerns"], tick),
      inventory: runtime["stock"] || [],
      coins: definition["coins"] || %{},
      mood: runtime["mood"],
      relationships: relationships(runtime, pc_slug),
      runtime: Map.take(runtime, ~w(since_tick resources public_facts concern_wait_ticks))
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
    |> Enum.map(&Map.put_new(&1, "since_tick", tick))
  end

  defp relationships(_runtime, nil), do: %{}

  defp relationships(runtime, pc_slug),
    do: %{pc_slug => Map.get(runtime, "relationship_score", 0.0)}

  defp opt(opts, key), do: Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
end
