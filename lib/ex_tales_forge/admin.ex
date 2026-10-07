defmodule TalesForge.Admin do
  @moduledoc """
  Admin context for sessions, NPC instances, turns, and NPC definition files.
  """

  import Ecto.Query

  require Logger

  alias TalesForge.NPC
  alias TalesForge.Repo
  alias TalesForge.Schemas.{GameSession, NpcInstance, Scene, Turn}

  @doc "Row counts for the admin dashboard."
  def stats do
    %{
      sessions: Repo.aggregate(GameSession, :count, :id),
      active_sessions:
        GameSession
        |> where([s], s.status == "active")
        |> Repo.aggregate(:count, :id),
      turns: Repo.aggregate(Turn, :count, :id),
      npc_instances: Repo.aggregate(NpcInstance, :count, :id),
      scenes: Repo.aggregate(Scene, :count, :id)
    }
  end

  @doc "Every session, newest first, with its turn count, location and character name."
  def list_sessions do
    sessions =
      GameSession
      |> order_by([s], desc: s.inserted_at)
      |> Repo.all()

    counts = turn_counts(Enum.map(sessions, & &1.id))

    Enum.map(sessions, fn session ->
      %{
        session: session,
        turn_count: Map.get(counts, session.id, 0),
        location_name: session_location(session),
        character_name: session_character_name(session)
      }
    end)
  end

  def get_session!(id, opts \\ []) do
    preloads = Keyword.get(opts, :preload, [])

    GameSession
    |> Repo.get!(id)
    |> Repo.preload(preloads)
  end

  @doc "A changeset for the admin session form (name, status, world state, clock)."
  def change_session(%GameSession{} = session, attrs \\ %{}) do
    GameSession.changeset(session, attrs)
  end

  def update_session(%GameSession{} = session, attrs) do
    session
    |> GameSession.changeset(attrs)
    |> Repo.update()
  end

  def update_session_world_state(session, json_string)
      when is_binary(json_string) do
    id = Map.get(session, :id)
    ecto_session = Repo.get!(GameSession, id)

    with {:ok, world_state} <- decode_json_map(json_string),
         {:ok, updated} <- update_session(ecto_session, %{world_state: world_state}) do
      {:ok, updated}
    end
  end

  @doc """
  Deletes the session. The foreign keys cascade: turns, scenes, NPC instances,
  session events, front instances and playtest runs go with it; AI call rows
  keep their data with `game_session_id` set to NULL.
  """
  def delete_session(session) do
    id = Map.get(session, :id)
    name = Map.get(session, :name, "unknown")
    Logger.info("admin deleting session id=#{id} name=#{name}")

    case Repo.get(GameSession, id) do
      nil -> :ok
      found -> Repo.delete!(found)
    end

    :ok
  end

  def reset_session_npcs(session) do
    id = Map.get(session, :id)

    from(n in NpcInstance, where: n.game_session_id == ^id)
    |> Repo.delete_all()

    # For seed/refresh we need the Ecto struct or world_state; fetch fresh
    ecto_session = Repo.get!(GameSession, id)
    :ok = NPC.seed_session(ecto_session)

    case NPC.refresh_session_world_state(ecto_session) do
      {:ok, refreshed} -> {:ok, refreshed}
      error -> error
    end
  end

  def list_npc_instances(session_id) do
    NpcInstance
    |> where([n], n.game_session_id == ^session_id)
    |> order_by([n], asc: n.npc_id)
    |> Repo.all()
  end

  def get_npc_instance!(session_id, npc_id) do
    NpcInstance
    |> where([n], n.game_session_id == ^session_id and n.npc_id == ^npc_id)
    |> Repo.one!()
  end

  @doc """
  The NPC instance for the `npc_id` slug in that session, or `nil` when the
  session has no such NPC. Same lookup as `get_npc_instance!/2`.
  """
  def get_npc_instance(session_id, npc_id) do
    NpcInstance
    |> where([n], n.game_session_id == ^session_id and n.npc_id == ^npc_id)
    |> Repo.one()
  end

  @doc "A changeset for the admin NPC form (personality, runtime state, disposition)."
  def change_npc_instance(%NpcInstance{} = instance, attrs \\ %{}) do
    NpcInstance.admin_changeset(instance, attrs)
  end

  @doc "Saves the admin NPC form; only personality, runtime state and disposition change."
  def save_npc_instance(%NpcInstance{} = instance, attrs) do
    instance
    |> NpcInstance.admin_changeset(attrs)
    |> Repo.update()
  end

  def update_npc_instance(%NpcInstance{} = instance, attrs) do
    instance
    |> NpcInstance.changeset(attrs)
    |> Repo.update()
  end

  def update_npc_runtime_state(%NpcInstance{} = instance, json_string)
      when is_binary(json_string) do
    with {:ok, runtime_state} <- decode_json_map(json_string),
         {:ok, instance} <- update_npc_instance(instance, %{runtime_state: runtime_state}) do
      {:ok, instance}
    end
  end

  def list_turns(session_id) do
    Turn
    |> where([t], t.game_session_id == ^session_id)
    |> order_by([t], desc: t.turn_number)
    |> Repo.all()
  end

  def get_turn!(session_id, turn_id) do
    Turn
    |> where([t], t.game_session_id == ^session_id and t.id == ^turn_id)
    |> Repo.one!()
  end

  @doc """
  Summaries of the NPC definition files in `priv/npcs`. The admin pages show
  these read-only; the files are edited in git.
  """
  def list_npc_definitions do
    npc_dir()
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.map(&load_npc_definition_summary/1)
    |> Enum.sort_by(& &1.id)
  end

  @doc "The decoded NPC definition file for `npc_id`; raises `ArgumentError` if there is none."
  def get_npc_definition!(npc_id) do
    path = npc_definition_path(npc_id)

    if valid_npc_id?(npc_id) and File.exists?(path) do
      path
      |> File.read!()
      |> Jason.decode!()
    else
      raise ArgumentError, "NPC definition '#{npc_id}' not found"
    end
  end

  def npc_definition_json(npc_id) do
    npc_id
    |> get_npc_definition!()
    |> Jason.encode!(pretty: true)
  end

  def encode_json(data) do
    Jason.encode!(data, pretty: true)
  end

  def decode_json_map(json_string) when is_binary(json_string) do
    case Jason.decode(json_string) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, "JSON must be an object"}
      {:error, reason} -> {:error, "Invalid JSON: #{inspect(reason)}"}
    end
  end

  defp turn_counts([]), do: %{}

  defp turn_counts(session_ids) do
    Turn
    |> where([t], t.game_session_id in ^session_ids)
    |> group_by([t], t.game_session_id)
    |> select([t], {t.game_session_id, count(t.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp session_location(session) do
    world_state = Map.get(session, :world_state, %{}) || %{}
    Map.get(world_state, "location_name", Map.get(world_state, "location_id", "—"))
  end

  defp session_character_name(session) do
    world_state = Map.get(session, :world_state, %{}) || %{}
    get_in(world_state, ["character", "name"]) || "—"
  end

  defp load_npc_definition_summary(file) do
    definition = npc_dir() |> Path.join(file) |> File.read!() |> Jason.decode!()
    id = Map.get(definition, "id", Path.rootname(file))

    %{
      id: id,
      name: Map.get(definition, "name", id),
      role: Map.get(definition, "role", "—"),
      default_location_id: Map.get(definition, "default_location_id", "—"),
      file: file
    }
  end

  defp npc_definition_path(npc_id) do
    Path.join(npc_dir(), "#{npc_id}.json")
  end

  # Slugs only, so a crafted URL can't read files outside priv/npcs.
  defp valid_npc_id?(npc_id), do: is_binary(npc_id) and npc_id =~ ~r/\A[a-z0-9_]+\z/

  # Resolved at runtime (not a module attribute): in a release priv is not at its build path.
  defp npc_dir, do: Path.join(:code.priv_dir(:ex_tales_forge), "npcs")
end
