defmodule TalesForge.Game.TurnProcessor do
  @moduledoc """
  Tier 2 GM response, server mechanics, and session persistence.

  ## Core runtime invariant
  This module and everything it calls must remain 100% Ecto-based for
  live game state. Ash (AdminResources or Authoring) is not allowed here.
  """

  require Logger

  alias TalesForge.Fronts
  alias TalesForge.Game.ActionHandler
  alias TalesForge.Game.Context
  alias TalesForge.Game.Events
  alias TalesForge.Game.Inventory
  alias TalesForge.Game.Mechanics
  alias TalesForge.Game.Perception
  alias TalesForge.Game.SceneProcessor
  alias TalesForge.Game.Schemas.{GMStructuredResponse, MechanicalResolution, PlayerAction}
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
         gm_context <- Context.build_gm_context(session),
         {:ok, gm_result} <-
           LLM.complete_turn(
             TalesForge.Game.Prompts.gm_system(),
             Context.format_gm_prompt(gm_context),
             player_action,
             handler,
             turn_number
           ),
         {character, mechanical} <-
           apply_mechanics(
             session.world_state,
             gm_result.mechanical_resolution.skill,
             player_action,
             handler
           ),
         {:ok, payload} <-
           finalize_turn(
             session,
             turn_number,
             raw_action,
             player_action,
             handler,
             mechanical,
             gm_result,
             character
           ) do
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
  def simulate!(session, raw_action, player_action, handler, mechanical) do
    gm_result = %GMStructuredResponse{
      narrative: "ok",
      mechanical_resolution: mechanical,
      state_updates: [],
      context_summary: nil
    }

    character = Map.get(session.world_state || %{}, "character", %{})
    turn_number = next_turn_number(session.id)

    finalize_turn(
      session,
      turn_number,
      raw_action,
      player_action,
      handler,
      mechanical,
      gm_result,
      character
    )
  end

  defp finalize_turn(
         session,
         turn_number,
         raw_action,
         player_action,
         handler,
         mechanical,
         gm_result,
         character
       ) do
    world_before = session.world_state || %{}
    world_moved = apply_world_updates(session, character, handler, gm_result, player_action)
    fronts = Fronts.sim_fronts(session.id)

    events =
      Events.from_turn(player_action, handler, mechanical, world_before, world_moved, fronts)

    {:ok, sim} = WorldSim.tick(%{fronts: fronts, events: events})

    hidden = Enum.reject(events, & &1["player_aware"])

    world_after =
      world_moved
      |> Perception.scrub_situation_lines(hidden)
      |> Perception.snapshot_public_facts(sim.fronts)

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
         :ok <- NPCRegistry.sync(session),
         :ok <- NPCSignals.emit_turn_signals(session.id, world_after, handler, raw_action) do
      {:ok,
       %{
         session_id: session.id,
         turn_count: turn_number,
         entries: build_entries(raw_action, gm_result.narrative, mechanical, turn.id),
         mechanical_resolution: MechanicalResolution.encode(mechanical),
         llm_provider: LLM.provider(),
         llm_source: LLM.llm_source(LLM.provider()),
         location_name: Map.get(world_after, "location_name"),
         world_state: world_after,
         needs_scene: SceneProcessor.needs_scene?(world_after)
       }}
    end
  end

  defp apply_mechanics(world_state, gm_skill, player_action, handler) do
    character = Map.get(world_state, "character", %{})

    case Mechanics.apply_server_mechanics(character, gm_skill, player_action, handler) do
      {updated, %MechanicalResolution{} = resolution} -> {updated, resolution}
      %MechanicalResolution{} = resolution -> {character, resolution}
    end
  end

  defp apply_world_updates(%GameSession{} = session, character, handler, gm_result, player_action) do
    base_world = session.world_state || %{}

    character =
      gm_result.state_updates
      |> character_patches()
      |> Enum.reduce(character, &deep_merge_maps/2)

    advanced_world =
      base_world
      |> put_in(["character"], character)
      |> maybe_move(handler)
      |> maybe_apply_inventory(session.id, player_action.action, handler)
      |> maybe_apply_context_summary(gm_result.context_summary)
      |> WorldClock.advance(ActionHandler.tick_delta(handler))

    world_tick = Map.get(advanced_world, "world_tick")
    :ok = NPC.apply_gm_updates(session.id, gm_result, world_tick)

    location_id = get_in(advanced_world, ["character", "location_id"])
    location = World.runtime_location(advanced_world, location_id)

    advanced_world
    |> Map.put("location_id", location_id)
    |> Map.put(
      "location_name",
      Map.get(location, "name", Map.get(advanced_world, "location_name"))
    )
    |> Map.put("present_npcs", NPC.sync_present_npcs(session.id, location_id))
    |> Map.put("npc_state", NPC.refresh_world_npc_state(session.id))
  end

  defp character_patches(state_updates) do
    state_updates
    |> List.wrap()
    |> Enum.filter(fn
      %{"path" => "characters/" <> _} -> true
      _ -> false
    end)
    |> Enum.map(&Map.get(&1, "patch", %{}))
  end

  defp deep_merge_maps(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, l, r ->
      if is_map(l) and is_map(r), do: deep_merge_maps(l, r), else: r
    end)
  end

  defp deep_merge_maps(_left, right), do: right

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

    event_multi =
      events
      |> Enum.with_index()
      |> Enum.reduce(
        Ecto.Multi.new()
        |> Ecto.Multi.update(
          :session,
          GameSession.changeset(session, %{world_state: world_state})
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
         |> Repo.transaction() do
      {:ok, result} -> {:ok, result}
      {:error, _step, reason, _} -> {:error, reason}
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

  defp build_entries(raw_action, narrative, mechanical, turn_id) do
    [
      %{id: "#{turn_id}-player", role: "player", text: raw_action},
      %{
        id: "#{turn_id}-gm",
        role: "gm",
        text: narrative,
        mechanical: MechanicalResolution.encode(mechanical)
      }
    ]
  end
end
