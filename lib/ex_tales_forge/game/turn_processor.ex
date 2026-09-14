defmodule TalesForge.Game.TurnProcessor do
  @moduledoc """
  Turn pipeline: board first, then one table GM, then one Multi.

  PlayerAction → handler → server mechanics → inventory → clock+move →
  events → WorldSim → Perception → table GM (tone only) → allow-listed
  patches → Multi → sync/signals → turn_completed.

  Core runtime is 100% Ecto. Ash is not allowed here.
  """

  require Logger

  alias TalesForge.Fronts
  alias TalesForge.Game.ActionHandler
  alias TalesForge.Game.Context
  alias TalesForge.Game.Events
  alias TalesForge.Game.Inventory
  alias TalesForge.Game.Mechanics
  alias TalesForge.Game.Perception
  alias TalesForge.Game.Prompts
  alias TalesForge.Game.SceneProcessor
  alias TalesForge.Game.Schemas.{GMStructuredResponse, MechanicalResolution, PlayerAction}
  alias TalesForge.Game.Train
  alias TalesForge.Game.World
  alias TalesForge.Game.WorldClock
  alias TalesForge.Game.WorldSim
  alias TalesForge.LLM
  alias TalesForge.NPC
  alias TalesForge.NPCRegistry
  alias TalesForge.NPCSignals
  alias TalesForge.PubSub.GameSession, as: SessionPubSub
  alias TalesForge.Repo
  alias TalesForge.Schemas.{GameSession, SessionEvent, Turn}

  def run(session_id, raw_action, player_action_map) do
    started = System.monotonic_time(:millisecond)
    player_action = PlayerAction.decode(player_action_map)

    with %GameSession{} = session <- Repo.get(GameSession, session_id),
         turn_number <- next_turn_number(session_id),
         handler <- ActionHandler.resolve(player_action),
         {character, mechanical} <- apply_mechanics(session.world_state, player_action, handler),
         %{
           world: world_board,
           events: events,
           sim: sim,
           improvements: improvements,
           training: training
         } <-
           apply_board(session, character, handler, player_action, mechanical),
         mechanical <- %{mechanical | improvements: improvements, training: training},
         gm_context <- Context.build_gm_context(%{session | world_state: world_board}),
         user <- Context.format_gm_prompt(gm_context) <> Context.mechanical_bounds(mechanical),
         {:ok, gm_result} <-
           LLM.complete_turn(
             Prompts.gm_system(),
             user,
             player_action,
             handler,
             turn_number
           ),
         world_final <- apply_allowlisted_patches(world_board, gm_result),
         {:ok, payload} <-
           persist_and_signal(session, world_final, turn_number, raw_action, %{
             handler: handler,
             mechanical: mechanical,
             gm_result: gm_result,
             events: events,
             sim: sim
           }) do
      elapsed = System.monotonic_time(:millisecond) - started

      Logger.info(
        "turn completed session=#{session_id} turn=#{turn_number} duration_ms=#{elapsed} llm_source=#{LLM.llm_source(LLM.provider())}"
      )

      SessionPubSub.broadcast(session_id, {:turn_completed, payload})
      {:ok, payload}
    else
      nil ->
        {:error, :not_found}

      {:error, reason} = err ->
        Logger.error("turn processor failed session=#{session_id} reason=#{inspect(reason)}")
        SessionPubSub.broadcast(session_id, {:turn_failed, inspect(reason)})
        err
    end
  end

  @doc false
  def simulate!(session, raw_action, player_action, handler, mechanical, opts \\ []) do
    gm_result = %GMStructuredResponse{
      narrative: "ok",
      state_updates: [],
      context_summary: nil
    }

    character = Map.get(session.world_state || %{}, "character", %{})
    turn_number = next_turn_number(session.id)

    %{
      world: world_board,
      events: events,
      sim: sim,
      improvements: improvements,
      training: training
    } =
      apply_board(session, character, handler, player_action, mechanical, opts)

    persist_and_signal(session, world_board, turn_number, raw_action, %{
      handler: handler,
      mechanical: %{mechanical | improvements: improvements, training: training},
      gm_result: gm_result,
      events: events,
      sim: sim
    })
  end

  @doc false
  def apply_board(session, character, handler, player_action, mechanical, opts \\ []) do
    world_before = session.world_state || %{}

    world_present =
      world_before
      |> put_in(["character"], character)
      |> maybe_apply_inventory(session.id, player_action.action, handler)
      |> maybe_move(handler)
      |> apply_location_presence(session)

    {world_paused, improvements, training} =
      apply_pause_or_train(world_present, session, handler, player_action, opts)

    fronts = Fronts.sim_fronts(session.id)
    people = NPC.sim_people(session.id)

    events =
      Events.from_turn(
        player_action,
        handler,
        mechanical,
        world_before,
        world_paused,
        fronts,
        people
      )

    {:ok, sim} = WorldSim.tick(%{fronts: fronts, people: people, events: events})
    hidden = Enum.reject(events, & &1["player_aware"])

    world =
      world_paused
      |> Perception.scrub_situation_lines(hidden)
      |> Perception.snapshot_public_facts(sim.fronts ++ sim.people)
      |> Mechanics.apply_vitality(mechanical, opts)

    %{
      world: world,
      events: events,
      sim: sim,
      improvements: improvements,
      training: training
    }
  end

  defp apply_pause_or_train(world, session, %{handler: "train"}, player_action, opts) do
    apply_training(world, session, player_action, opts)
  end

  defp apply_pause_or_train(world, _session, handler, _player_action, opts) do
    world_moved = WorldClock.advance(world, ActionHandler.tick_delta(handler))
    {world_improved, improvements} = maybe_attempt_improvements(world_moved, handler, opts)
    {world_improved, improvements, nil}
  end

  defp apply_training(world, session, player_action, opts) do
    action = player_action.action
    npc_id = action.target
    present_ids = Map.get(world, "present_npcs", [])
    npc_def = trainer_personality(session.id, npc_id)
    character = Map.get(world, "character", %{})

    {taught, improvements, training, ticks} =
      Train.apply(character, npc_def, present_ids, action, opts)

    world =
      world
      |> put_in(["character"], taught)
      |> WorldClock.advance(ticks)

    {world, improvements, training}
  end

  defp trainer_personality(session_id, npc_id) when is_binary(npc_id) and npc_id != "" do
    case NPC.get_instance(session_id, npc_id) do
      %{personality: personality} when is_map(personality) -> personality
      _ -> %{}
    end
  end

  defp trainer_personality(_session_id, _npc_id), do: %{}

  defp maybe_attempt_improvements(world, handler, opts) do
    pause? =
      handler.handler == "wait" and
        ActionHandler.tick_delta(handler) >= WorldClock.ticks_per_hour()

    if pause? do
      rolls = opts[:improvement_rolls] || %{}
      character = Map.get(world, "character", %{})
      {improved, improvements} = Mechanics.attempt_improvements(character, rolls)
      {put_in(world, ["character"], improved), improvements}
    else
      {world, []}
    end
  end

  defp persist_and_signal(session, world_after, turn_number, raw_action, ctx) do
    %{
      handler: handler,
      mechanical: mechanical,
      gm_result: gm_result,
      events: events,
      sim: sim
    } = ctx

    with {:ok, %{session: session, turn: turn}} <-
           persist_turn_multi(
             session,
             world_after,
             turn_number,
             raw_action,
             gm_result,
             mechanical,
             events,
             sim
           ),
         :ok <-
           NPC.apply_gm_updates(
             session.id,
             %{gm_result | state_updates: []},
             Map.get(world_after, "world_tick")
           ),
         :ok <- NPCRegistry.sync(session),
         :ok <- maybe_emit_turn_signals(session, world_after, handler, raw_action) do
      {:ok,
       %{
         session_id: session.id,
         turn_count: turn_number,
         entries: build_entries(raw_action, gm_result.narrative, turn.id),
         mechanical_resolution: MechanicalResolution.encode(mechanical),
         llm_provider: LLM.provider(),
         llm_source: LLM.llm_source(LLM.provider()),
         location_name: Map.get(world_after, "location_name"),
         world_state: world_after,
         session_status: session.status,
         needs_scene: SceneProcessor.needs_scene?(world_after)
       }}
    end
  end

  defp maybe_emit_turn_signals(%{status: "dead"}, _world_after, _handler, _raw_action), do: :ok

  defp maybe_emit_turn_signals(session, world_after, handler, raw_action) do
    if Mechanics.dead?(world_after) do
      :ok
    else
      NPCSignals.emit_turn_signals(
        session.id,
        world_after,
        handler,
        raw_action,
        session.world_state
      )
    end
  end

  defp apply_mechanics(world_state, player_action, handler) do
    character = Map.get(world_state || %{}, "character", %{})
    Mechanics.apply_server_mechanics(character, player_action, handler)
  end

  defp apply_allowlisted_patches(world, gm_result) do
    maybe_apply_context_summary(world, gm_result.context_summary)
  end

  defp apply_location_presence(world_state, %GameSession{} = session) do
    location_id = get_in(world_state, ["character", "location_id"])
    location = World.runtime_location(world_state, location_id)

    world_state
    |> Map.put("location_id", location_id)
    |> Map.put(
      "location_name",
      Map.get(location, "name", Map.get(world_state, "location_name"))
    )
    |> Map.put("present_npcs", NPC.sync_present_npcs(session.id, location_id))
    |> Map.put("npc_state", NPC.refresh_world_npc_state(session.id))
  end

  defp maybe_move(world_state, %{handler: "move", state_hints: %{"location_id" => location_id}})
       when is_binary(location_id) do
    put_in(world_state, ["character", "location_id"], location_id)
  end

  defp maybe_move(world_state, %{handler: "move", target: target}) when is_binary(target) do
    put_in(world_state, ["character", "location_id"], target)
  end

  defp maybe_move(world_state, _), do: world_state

  defp maybe_apply_inventory(world_state, session_id, action, handler) do
    case Inventory.apply_server_inventory(world_state, session_id, action, handler) do
      {:ok, updated, %{applied: applied}} when is_list(applied) ->
        Logger.info("inventory applied session=#{session_id} changes=#{inspect(applied)}")
        updated

      {:ok, updated, _} ->
        updated

      {:error, reason} ->
        Logger.warning("inventory skipped session=#{session_id} reason=#{reason}")
        world_state
    end
  end

  defp maybe_apply_context_summary(world_state, nil), do: world_state

  defp maybe_apply_context_summary(world_state, summary) do
    lines =
      summary
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Map.put(world_state, "situation_lines", lines)
  end

  defp persist_turn_multi(
         session,
         world_state,
         turn_number,
         raw_action,
         gm_result,
         mechanical,
         events,
         sim
       ) do
    turn_cs =
      %Turn{}
      |> Turn.changeset(%{
        game_session_id: session.id,
        turn_number: turn_number,
        player_action: raw_action,
        narrative: gm_result.narrative,
        mechanical_resolution: MechanicalResolution.encode(mechanical)
      })

    attrs = session_attrs(world_state)

    event_multi =
      events
      |> Enum.with_index()
      |> Enum.reduce(
        Ecto.Multi.new()
        |> Ecto.Multi.update(
          :session,
          GameSession.changeset(session, attrs)
        )
        |> Ecto.Multi.insert(:turn, turn_cs),
        fn {ev, idx}, acc ->
          cs =
            %SessionEvent{}
            |> SessionEvent.changeset(%{
              game_session_id: session.id,
              kind: ev["kind"],
              actor: ev["actor"],
              player_aware: ev["player_aware"],
              tick: ev["tick"],
              location_id: ev["location_id"],
              payload: ev["payload"] || %{}
            })

          Ecto.Multi.insert(acc, {:event, idx}, cs)
        end
      )

    case event_multi
         |> Fronts.persist_tick_multi(session.id, sim)
         |> NPC.persist_tick_multi(session.id, sim)
         |> Repo.transaction() do
      {:ok, result} -> {:ok, result}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  defp session_attrs(world_state) do
    attrs = %{world_state: world_state}

    if Mechanics.dead?(world_state) do
      Map.put(attrs, :status, "dead")
    else
      attrs
    end
  end

  defp next_turn_number(session_id) do
    import Ecto.Query

    Turn
    |> where([t], t.game_session_id == ^session_id)
    |> select([t], max(t.turn_number))
    |> Repo.one()
    |> case do
      nil -> 1
      n -> n + 1
    end
  end

  defp build_entries(raw_action, narrative, turn_id) do
    [
      %{id: "#{turn_id}-player", role: "player", text: raw_action},
      %{id: "#{turn_id}-gm", role: "gm", text: narrative}
    ]
  end
end
