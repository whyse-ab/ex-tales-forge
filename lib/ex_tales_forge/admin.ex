defmodule TalesForge.Admin do
  @moduledoc """
  Admin context for sessions, NPC instances, turns, and NPC definition files.
  """

  import Ecto.Query

  require Ash.Query
  require Logger

  alias TalesForge.NPC
  alias TalesForge.Repo
  alias TalesForge.Schemas.{GameSession, NpcInstance, Scene, Turn}

  def stats do
    # Use Ash for admin stats where possible (falls back to Ecto)
    %{
      sessions: length(Ash.read!(TalesForge.AdminResources.GameSession)),
      active_sessions:
        length(
          Ash.read!(
            TalesForge.AdminResources.GameSession
            |> Ash.Query.filter(status: :active)
          )
        ),
      turns: length(Ash.read!(TalesForge.AdminResources.Turn)),
      npc_instances: length(Ash.read!(TalesForge.AdminResources.NpcInstance)),
      scenes: length(Ash.read!(TalesForge.AdminResources.Scene))
    }
  rescue
    # Fallback during initial wiring
    _ ->
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

  def list_sessions do
    # Example of using Ash for admin listing of runtime sessions.
    # Game play paths still use the plain Ecto GameSessions module.
    ash_sessions =
      Ash.read!(
        TalesForge.AdminResources.GameSession
        |> Ash.Query.sort(inserted_at: :desc),
        load: []
      )

    counts = turn_counts(Enum.map(ash_sessions, & &1.id))

    Enum.map(ash_sessions, fn session ->
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

  def delete_session(session) do
    id = Map.get(session, :id)
    name = Map.get(session, :name, "unknown")
    Logger.info("admin deleting session id=#{id} name=#{name}")

    case Ash.get(TalesForge.AdminResources.GameSession, id) do
      {:ok, ash_session} -> Ash.destroy!(ash_session)
      _ -> :ok
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

  def list_npc_definitions do
    case load_npc_definitions_from_ash() do
      defs when is_list(defs) and defs != [] -> defs
      _ -> list_npc_definitions_from_files()
    end
  end

  defp load_npc_definitions_from_ash do
    case Ash.read(TalesForge.Authoring.NpcDefinition, load: []) do
      {:ok, records} ->
        records
        |> Enum.map(fn rec ->
          %{
            id: rec.npc_id,
            name: rec.name,
            role: rec.role,
            default_location_id: rec.default_location_id || "—",
            file: "(Ash)"
          }
        end)
        |> Enum.sort_by(& &1.id)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp list_npc_definitions_from_files do
    npc_dir()
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.map(&load_npc_definition_summary/1)
    |> Enum.sort_by(& &1.id)
  end

  def get_npc_definition!(npc_id) do
    case load_npc_definition_from_ash(npc_id) do
      {:ok, defn} -> defn
      _ -> load_npc_definition_from_file!(npc_id)
    end
  end

  defp load_npc_definition_from_ash(npc_id) do
    case Ash.get(TalesForge.Authoring.NpcDefinition, npc_id, load: []) do
      {:ok, %TalesForge.Authoring.NpcDefinition{} = rec} ->
        {:ok,
         %{
           "id" => rec.npc_id,
           "name" => rec.name,
           "race" => rec.race,
           "role" => rec.role,
           "default_location_id" => rec.default_location_id,
           "appearance" => rec.appearance,
           "personality" => rec.personality,
           "backstory" => rec.backstory,
           "motivations" => rec.motivations || %{},
           "stock" => rec.stock || [],
           "portrait_url" => rec.portrait_url
         }}

      _ ->
        {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  defp load_npc_definition_from_file!(npc_id) do
    path = npc_definition_path(npc_id)

    if File.exists?(path) do
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

  def save_npc_definition(npc_id, json_string) when is_binary(json_string) do
    with {:ok, definition} <- decode_json_map(json_string),
         :ok <- validate_npc_definition(definition),
         :ok <- write_npc_definition_file(npc_id, definition),
         :ok <- upsert_npc_definition_to_ash(npc_id, definition) do
      {:ok, definition}
    end
  end

  defp upsert_npc_definition_to_ash(npc_id, definition) do
    attrs = %{
      npc_id: npc_id,
      name: Map.get(definition, "name", npc_id),
      race: Map.get(definition, "race", "human"),
      role: Map.get(definition, "role"),
      default_location_id: Map.get(definition, "default_location_id"),
      appearance: Map.get(definition, "appearance"),
      personality: Map.get(definition, "personality"),
      backstory: Map.get(definition, "backstory"),
      motivations: Map.get(definition, "motivations", %{}),
      stock: Map.get(definition, "stock", []),
      portrait_url: Map.get(definition, "portrait_url")
    }

    case Ash.get(TalesForge.Authoring.NpcDefinition, npc_id, load: []) do
      {:ok, existing} ->
        TalesForge.Authoring.NpcDefinition.update!(existing, attrs)
        :ok

      _ ->
        TalesForge.Authoring.NpcDefinition.create!(attrs)
        :ok
    end
  rescue
    e -> {:error, "Ash upsert failed: #{inspect(e)}"}
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

  defp validate_npc_definition(definition) do
    cond do
      not is_map(definition) ->
        {:error, "Definition must be a JSON object"}

      blank?(Map.get(definition, "id")) ->
        {:error, "Definition requires id"}

      blank?(Map.get(definition, "name")) ->
        {:error, "Definition requires name"}

      true ->
        :ok
    end
  end

  defp write_npc_definition_file(npc_id, definition) do
    path = npc_definition_path(npc_id)
    tmp = path <> ".tmp"
    payload = Jason.encode!(definition, pretty: true) <> "\n"

    with :ok <- File.write(tmp, payload),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} -> {:error, "Could not save file: #{inspect(reason)}"}
    end
  end

  defp blank?(value), do: is_nil(value) or to_string(value) |> String.trim() == ""

  # Resolved at runtime (not a module attribute): in a release priv is not at its build path.
  defp npc_dir, do: Path.join(:code.priv_dir(:ex_tales_forge), "npcs")
end
