defmodule TalesForge.GameSessions do
  @moduledoc """
  Coordinates database sessions, Tier 1 intent, and Tier 2 Oban jobs.

  A core game runtime module: Ecto schemas (TalesForge.Schemas.*) and Repo only.
  """

  import Ecto.Query

  require Logger

  alias TalesForge.Agents.PlayerSessionAgent
  alias TalesForge.AICalls.{Steps, Tags}
  alias TalesForge.Characters
  alias TalesForge.Fronts
  alias TalesForge.Game.Context
  alias TalesForge.Game.Features
  alias TalesForge.Game.Intent
  alias TalesForge.Game.Mechanics
  alias TalesForge.Game.Pack
  alias TalesForge.Game.SceneProcessor
  alias TalesForge.Game.Schemas.PlayerAction
  alias TalesForge.Game.TurnProcessor
  alias TalesForge.Game.Variant
  alias TalesForge.Game.World
  alias TalesForge.NPC
  alias TalesForge.NPCRegistry
  alias TalesForge.PubSub.GameSession, as: SessionPubSub
  alias TalesForge.Repo
  alias TalesForge.Schemas.{GameSession, Scene}
  alias TalesForge.Workers.{ProcessScene, ProcessTurn}

  def list_sessions do
    GameSession
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  def get_session!(id), do: Repo.get!(GameSession, id)

  @character_opts [:controller, :controller_ref, :owner_player_id, :character]

  @doc """
  Creates a session with its world, NPCs, fronts and characters.

  Besides the session fields, `attrs` takes `:adventure_id` and the player
  character options `:controller` (`"player"` or `"bot"`), `:controller_ref`
  and `:owner_player_id` (see `TalesForge.Characters.seed_session/2`).

  `:character` is a created player character in the shape of a pack character
  file (`TalesForge.CharacterCreation.finalize/1`). It replaces the pack's
  default character (Elara) in `world_state["character"]` and gives the
  `characters` row its levers. An invalid one returns
  `{:error, {:invalid_character, message}}` and creates nothing.

  `:variant` is the behaviour variant (`TalesForge.Game.Variant`), stored in
  `world_state["variant"]` when it is not `"default"`; nil means
  `GAME_VARIANT`. An unknown one returns `{:error, :unknown_variant}`.
  """
  def create_session(attrs \\ %{}) do
    adventure_id = adventure_id_from(attrs)
    {variant, attrs} = pop_variant(attrs)

    character_opts =
      Map.take(attrs, @character_opts ++ Enum.map(@character_opts, &Atom.to_string/1))

    with {:ok, variant} <- Variant.cast(variant),
         {:ok, character} <- validate_character(character_opts),
         world =
           adventure_id
           |> materialize_world(variant)
           |> put_character(character)
           |> Variant.put(variant) do
      insert_session(attrs, adventure_id, world, character_opts)
    end
  end

  defp pop_variant(attrs) do
    variant = Map.get(attrs, :variant) || Map.get(attrs, "variant")
    {variant, Map.drop(attrs, [:variant, "variant"])}
  end

  defp insert_session(attrs, adventure_id, world, character_opts) do
    session_attrs =
      %{
        name: default_session_name(adventure_id),
        status: "active",
        world_state: world
      }
      |> Map.merge(Map.drop(attrs, [:adventure_id, "adventure_id"] ++ Map.keys(character_opts)))
      |> Map.put(:world_state, world)

    with {:ok, session} <-
           %GameSession{}
           |> GameSession.changeset(session_attrs)
           |> Repo.insert(),
         :ok <- NPC.seed_session(session),
         :ok <- Fronts.seed_session(session),
         {:ok, session} <- NPC.refresh_session_world_state(session),
         :ok <- Characters.seed_session(session, character_opts),
         :ok <- ensure_agent(session),
         :ok <- NPCRegistry.sync(session),
         {:ok, _} <- ensure_scene(session) do
      {:ok, Repo.preload(session, [:npc_instances, :front_instances])}
    end
  end

  defp validate_character(opts) do
    case Map.get(opts, :character) || Map.get(opts, "character") do
      nil ->
        {:ok, nil}

      character when is_map(character) ->
        {:ok, Pack.validate_player_character!(character, "created character")}

      other ->
        {:error, {:invalid_character, "expected a map, got #{inspect(other)}"}}
    end
  rescue
    e in ArgumentError -> {:error, {:invalid_character, Exception.message(e)}}
  end

  defp put_character(world, nil), do: world

  defp put_character(world, character) do
    sheet =
      character
      |> Pack.sheet()
      |> Map.delete("creation")
      |> Map.put("location_id", world["location_id"])

    Map.put(world, "character", sheet)
  end

  defp adventure_id_from(attrs) do
    Map.get(attrs, :adventure_id) || Map.get(attrs, "adventure_id") || "crossroads_ledger"
  end

  defp default_session_name("tin_valley"), do: "Tin Valley"
  defp default_session_name(_), do: "Crossroads Hamlet"

  # Dual path: complete packs fail-fast via Pack; Crossroads keeps today's seed.
  # The session's world features (INN_WORLD, WORLD_ANTAGONIST) are read here,
  # once, and stored in world_state["features"].
  defp materialize_world("tin_valley", variant),
    do: Pack.materialize("tin_valley", variant, Features.for_new_session(variant))

  defp materialize_world(_adventure_id, _variant), do: World.default_world_state()

  def scene_status(session_id) do
    session_id
    |> get_session!()
    |> SceneProcessor.scene_status()
  end

  def ensure_scene(%GameSession{} = session) do
    if SceneProcessor.needs_scene?(session.world_state) do
      enqueue_scene(session.id)
    else
      {:ok, :scene_ready}
    end
  end

  def ensure_scene(session_id) when is_binary(session_id) do
    session_id
    |> get_session!()
    |> ensure_scene()
  end

  def submit_message(session_id, text, opts \\ []) when is_binary(text) do
    trimmed = String.trim(text)

    if trimmed == "" do
      {:error, :empty_message}
    else
      with %GameSession{} = session <- Repo.get(GameSession, session_id),
           :ok <- reject_if_dead(session),
           :ok <- ensure_runtime_started(session),
           :ok <- require_scene_ready(session),
           {:ok, outcome} <- resolve_and_enqueue(session, trimmed, opts) do
        {:ok, outcome}
      else
        nil -> {:error, :not_found}
        {:error, _} = err -> err
      end
    end
  end

  @doc "What the play page shows as the story so far. Needs `:turns` and `:scenes` preloaded."
  def transcript(%GameSession{} = session) do
    scene_rows =
      Enum.map(session.scenes, fn scene ->
        {scene.inserted_at, SceneProcessor.build_entry(scene)}
      end)

    turn_rows =
      session.turns
      |> Enum.sort_by(& &1.turn_number)
      |> Enum.flat_map(fn turn ->
        [
          {turn.inserted_at,
           %{id: "#{turn.id}-player", role: "player", text: turn.player_action}},
          {turn.inserted_at, %{id: "#{turn.id}-gm", role: "gm", text: turn.narrative || ""}}
        ]
      end)

    (scene_rows ++ turn_rows)
    |> Enum.sort_by(fn {inserted_at, _} -> inserted_at end, DateTime)
    |> Enum.map(fn {_inserted_at, entry} -> entry end)
  end

  @doc """
  The GM's opening narration: the session's first scene (generated by the scene
  job `create_session/1` enqueues), or nil until it exists. Players cannot act
  before it (`submit_message/3` returns `{:error, :needs_scene}`).
  """
  def opening_scene(session_id) when is_binary(session_id) do
    Scene
    |> where([s], s.game_session_id == ^session_id)
    |> order_by(asc: :inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  def ensure_agent_started(%GameSession{} = session) do
    ensure_runtime_started(session)
  end

  def ensure_agent_started(session_id) when is_binary(session_id) do
    session_id
    |> get_session!()
    |> ensure_runtime_started()
  end

  def ensure_runtime_started(%GameSession{} = session) do
    with :ok <- ensure_agent(session),
         :ok <- NPCRegistry.sync(session) do
      :ok
    end
  end

  def agent_id(session_id), do: "session-#{session_id}"

  defp resolve_and_enqueue(%GameSession{} = session, raw_action, opts) do
    context = Context.build_intent_context(session)
    started_at = DateTime.utc_now()
    started = System.monotonic_time(:millisecond)

    try do
      {player_action, intent_source} =
        build_player_action(session, raw_action, context, opts)

      elapsed = System.monotonic_time(:millisecond) - started
      record_intent_step(session, started_at, elapsed)

      Logger.info(
        "intent resolved session=#{session.id} duration_ms=#{elapsed} source=#{intent_source}"
      )

      enqueue_turn(session, raw_action, player_action)
    rescue
      e in [Intent.ClarificationNeeded] ->
        record_intent_step(session, started_at, System.monotonic_time(:millisecond) - started)
        clarification = Intent.build_clarification(e.extraction, raw_action)
        save_clarification(session, clarification)
        SessionPubSub.broadcast(session.id, {:clarification_needed, clarification})
        {:ok, %{status: :clarification, clarification: clarification}}
    end
  end

  # Intent extraction + validation (heuristic, or the tier-1 LLM call, which has
  # its own llm row): the Elixir step before the turn job, on the player's clock.
  defp record_intent_step(session, started_at, elapsed_ms) do
    %{
      purpose: "turn.intent",
      latency_ms: elapsed_ms,
      started_at: started_at,
      game_session_id: session.id,
      turn_number: TurnProcessor.next_turn_number(session.id)
    }
    |> Map.merge(Tags.for_world(session.world_state))
    |> Steps.record_one()
  end

  defp build_player_action(%GameSession{} = session, raw_action, context, opts) do
    option_id = Keyword.get(opts, :option_id)
    clarification_id = Keyword.get(opts, :clarification_id)

    cond do
      option_id && clarification_id ->
        {resolve_clarification_option(session, context, clarification_id, option_id),
         :clarification}

      clarification_id && raw_action != "" ->
        pending = get_pending(session, clarification_id)
        enriched = pending["raw_action"] <> "\nClarification: " <> raw_action
        {Intent.extract_intent(enriched, context), :llm}

      true ->
        {bundle, source} = Intent.resolve_bundle(raw_action, context)

        if Intent.needs_clarification?(bundle) do
          raise Intent.ClarificationNeeded, extraction: bundle
        end

        {Intent.validate_player_action(bundle, context), source}
    end
  end

  defp resolve_clarification_option(session, context, clarification_id, option_id) do
    pending = get_pending(session, clarification_id)

    option =
      pending["options"]
      |> Enum.find(&(&1["id"] == option_id))

    if is_nil(option) do
      raise ArgumentError, "invalid clarification option"
    end

    extraction = %TalesForge.Game.Schemas.IntentExtraction{
      overall_intent: pending["overall_intent"],
      actions:
        pending
        |> Map.get("actions")
        |> case do
          nil -> [heuristic_from_pending(pending, option, context)]
          actions -> Enum.map(actions, &TalesForge.Game.Schemas.SingleAction.decode/1)
        end,
      primary_index: option["action_index"],
      confidence: pending["confidence"] || 1.0,
      needs_clarification: false
    }

    Intent.validate_player_action(extraction, context)
  end

  defp heuristic_from_pending(pending, option, context) do
    TalesForge.Game.Intent.heuristic_intent(
      "#{pending["raw_action"]} (#{option["label"]})",
      %{
        "exits" => [],
        "exit_names" => %{},
        "present_npcs" => [],
        "npc_details" => %{},
        "variant" => Variant.of(context)
      }
    )
    |> Map.get(:actions)
    |> List.first()
  end

  defp get_pending(%GameSession{} = session, clarification_id) do
    pending =
      session.world_state
      |> Map.get("pending_clarification")

    if pending && pending["clarification_id"] == clarification_id do
      pending
    else
      raise ArgumentError, "clarification expired"
    end
  end

  defp reject_if_dead(%GameSession{status: "dead"}), do: {:error, :dead}

  defp reject_if_dead(%GameSession{world_state: world}) do
    if Mechanics.dead?(world) do
      {:error, :dead}
    else
      :ok
    end
  end

  defp require_scene_ready(%GameSession{} = session) do
    if SceneProcessor.needs_scene?(session.world_state) do
      ensure_scene(session)
      {:error, :needs_scene}
    else
      :ok
    end
  end

  defp enqueue_scene(session_id) do
    %{session_id: session_id}
    |> ProcessScene.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        SessionPubSub.broadcast(session_id, {:scene_processing, %{}})
        {:ok, :processing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enqueue_turn(%GameSession{} = session, raw_action, %PlayerAction{} = player_action) do
    session
    |> clear_clarification()
    |> case do
      {:ok, session} ->
        %{
          session_id: session.id,
          raw_action: raw_action,
          player_action: PlayerAction.encode(player_action)
        }
        |> ProcessTurn.new()
        |> Oban.insert()
        |> case do
          {:ok, _job} ->
            SessionPubSub.broadcast(session.id, {:turn_processing, %{}})
            {:ok, %{status: :processing}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp save_clarification(%GameSession{} = session, clarification) do
    world_state = Map.put(session.world_state || %{}, "pending_clarification", clarification)

    session
    |> GameSession.changeset(%{world_state: world_state})
    |> Repo.update()
  end

  defp clear_clarification(%GameSession{} = session) do
    world_state = Map.delete(session.world_state || %{}, "pending_clarification")

    session
    |> GameSession.changeset(%{world_state: world_state})
    |> Repo.update()
  end

  defp ensure_agent(%GameSession{id: id}) do
    aid = agent_id(id)

    if TalesForge.Jido.whereis(aid) do
      :ok
    else
      case TalesForge.Jido.start_agent(PlayerSessionAgent,
             id: aid,
             initial_state: %{session_id: id, turn_count: 0, entries: []}
           ) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, {:already_registered, _pid}} -> :ok
        other -> other
      end
    end
  end
end
