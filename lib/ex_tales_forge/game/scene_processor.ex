defmodule TalesForge.Game.SceneProcessor do
  @moduledoc """
  Opening location exposition before player turns (v1 scene tier).
  """

  require Logger

  import Ecto.Query

  alias TalesForge.Game.Context
  alias TalesForge.Game.Mechanics
  alias TalesForge.Game.Prompts
  alias TalesForge.Game.World
  alias TalesForge.LLM
  alias TalesForge.NPC
  alias TalesForge.PubSub.GameSession, as: SessionPubSub
  alias TalesForge.Repo
  alias TalesForge.Schemas.{GameSession, Scene}

  def needs_scene?(world_state) when is_map(world_state) do
    location_id = Map.get(world_state, "location_id")
    last_scene = Map.get(world_state, "last_scene_location")

    not Mechanics.dead?(world_state) and is_binary(location_id) and location_id != last_scene
  end

  def needs_scene?(_), do: true

  def scene_status(%GameSession{} = session) do
    world = session.world_state || %{}

    %{
      needs_scene: needs_scene?(world),
      current_location: Map.get(world, "location_id"),
      last_scene_location: Map.get(world, "last_scene_location")
    }
  end

  def run(session_id) do
    started = System.monotonic_time(:millisecond)

    with %GameSession{} = session <- Repo.get(GameSession, session_id),
         true <- needs_scene?(session.world_state),
         {:ok, payload} <- describe_scene(session) do
      elapsed = System.monotonic_time(:millisecond) - started

      Logger.info(
        "scene completed session=#{session_id} location=#{payload.location_id} duration_ms=#{elapsed} llm_source=#{payload.llm_source}"
      )

      SessionPubSub.broadcast(session_id, {:scene_completed, payload})
      {:ok, payload}
    else
      nil ->
        {:error, :not_found}

      false ->
        {:ok, :scene_ready}

      {:error, reason} = err ->
        Logger.error("scene processor failed session=#{session_id} reason=#{inspect(reason)}")
        SessionPubSub.broadcast(session_id, {:scene_failed, SessionPubSub.failure_reason(reason)})
        err
    end
  end

  defp describe_scene(%GameSession{} = session) do
    world = session.world_state || %{}
    location_id = Map.get(world, "location_id", "weary_pilgrim")

    case load_scene(session.id, location_id) do
      %Scene{} = scene ->
        finalize_scene(session, scene, "cache")

      nil ->
        generate_scene(session, location_id)
    end
  end

  defp generate_scene(%GameSession{} = session, location_id) do
    gm_context = Context.build_gm_context(session)

    case LLM.complete_scene(Prompts.scene_messages(gm_context), gm_context.intent_context,
           session_id: session.id
         ) do
      {:ok, %{location_name: location_name, narrative: narrative}} ->
        image_url = World.scene_image_url(location_id)

        attrs = %{
          game_session_id: session.id,
          location_id: location_id,
          location_name: location_name,
          narrative: narrative,
          image_url: image_url
        }

        with {:ok, scene} <- persist_scene(attrs) do
          finalize_scene(session, scene, LLM.llm_source(LLM.provider()))
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finalize_scene(%GameSession{id: session_id}, %Scene{} = scene, llm_source) do
    session = Repo.get!(GameSession, session_id)

    world_state =
      session.world_state
      |> Map.put("last_scene_location", scene.location_id)
      |> Map.put("location_name", scene.location_name)

    with {:ok, session} <- persist_world_state(session, world_state),
         {:ok, session} <- NPC.refresh_session_world_state(session) do
      payload = %{
        session_id: session.id,
        location_id: scene.location_id,
        location_name: scene.location_name,
        image_url: scene.image_url,
        world_state: session.world_state,
        llm_source: llm_source,
        entries: [build_entry(scene)]
      }

      {:ok, payload}
    end
  end

  defp persist_world_state(%GameSession{} = session, world_state) do
    session
    |> GameSession.changeset(%{world_state: world_state})
    |> Repo.update()
  end

  defp persist_scene(attrs) do
    %Scene{}
    |> Scene.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:location_name, :narrative, :image_url]},
      conflict_target: [:game_session_id, :location_id]
    )
  end

  defp load_scene(session_id, location_id) do
    Scene
    |> where([s], s.game_session_id == ^session_id and s.location_id == ^location_id)
    |> Repo.one()
  end

  def build_entry(%Scene{} = scene) do
    %{
      id: "#{scene.id}-scene",
      role: "scene",
      location_name: scene.location_name,
      text: scene.narrative,
      image_url: scene.image_url
    }
  end
end
