defmodule TalesForge.Game.TurnProcessor do
  @moduledoc """
  Turn pipeline: board first, then one table GM, then one Multi.

  PlayerAction → handler → server mechanics → inventory → clock+move →
  events → WorldSim → Perception → vitality → banked LP spent on improvement
  attempts on a long rest (`TalesForge.Game.Progression`) → premise check (default variant: the
  player's claims about items, coins, purchases and kills checked against the
  session, `TalesForge.Game.PremiseCheck`) → table GM (tone only) → allow-listed
  patches → Multi → NPC updates → characters mirror → sync/signals → turn_completed.

  Default variant: on a long rest the skills that improved overnight go to the
  per-turn GM prompt (`TalesForge.Game.Context.rest_growth_section/1`) so the
  GM can narrate the character waking surer of them.

  Core runtime is 100% Ecto.
  """

  require Logger

  alias TalesForge.AICalls.{Steps, Tags}
  alias TalesForge.Characters
  alias TalesForge.Fronts
  alias TalesForge.Game.ActionHandler
  alias TalesForge.Game.Context
  alias TalesForge.Game.Events
  alias TalesForge.Game.Gestures
  alias TalesForge.Game.Inventory
  alias TalesForge.Game.Mechanics
  alias TalesForge.Game.NpcReactions
  alias TalesForge.Game.Perception
  alias TalesForge.Game.PremiseCheck
  alias TalesForge.Game.Progression
  alias TalesForge.Game.Progression.Tiered
  alias TalesForge.Game.Prompts
  alias TalesForge.Game.Reflection
  alias TalesForge.Game.SceneProcessor
  alias TalesForge.Game.Schemas.{GMStructuredResponse, MechanicalResolution, PlayerAction}
  alias TalesForge.Game.Train
  alias TalesForge.Game.Variant
  alias TalesForge.Game.World
  alias TalesForge.Game.WorldClock
  alias TalesForge.Game.WorldSim
  alias TalesForge.GMReasoning
  alias TalesForge.LLM
  alias TalesForge.NPC
  alias TalesForge.NPCRegistry
  alias TalesForge.NPCSignals
  alias TalesForge.PubSub.GameSession, as: SessionPubSub
  alias TalesForge.Repo
  alias TalesForge.Schemas.{GameSession, SessionEvent, Turn}
  alias TalesForge.World, as: WorldAgents
  alias TalesForge.World.{Extract, Prices}

  @doc """
  Runs one turn. The main steps (rules, prompt build, GM call, persistence)
  are timed and recorded in `ai_calls` as `call_type` `function` rows
  (`TalesForge.AICalls.Steps`), whether the turn succeeds or fails.

  `player_action_map` is the encoded `PlayerAction` from the intent step.
  Returns `{:ok, payload}` once the turn is persisted and broadcast, or
  `{:error, reason}` (also broadcast as `:turn_failed`).

  A crash in a step (a raise, throw or exit) is logged with its stacktrace,
  broadcast as `:turn_failed` and recorded on the step's row, then re-raised
  so the Oban job records it and retries. Before this a crashed turn was
  silent: the job failed three times, nothing was logged or broadcast, and
  the player (or the playtest runner) waited until its timeout.

  `opts` (set only by the Jev intent path, `INTENT_JEV=on`):

    * `:gm_quote` — the text the GM gets as the action's `overall_intent`: the
      player's own words when the safety read was confidently benign, else a
      typed summary (`TalesForge.Game.PlayerQuote`). The rules still read
      `player_action_map`.
    * `:gm_note` — `"decline_nefarious"`: the GM declines the request in
      character (`TalesForge.Game.Context.player_request_section/1`).

  Without them the GM prompt is byte-identical to before.
  """
  @spec run(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(session_id, raw_action, player_action_map, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    case Repo.get(GameSession, session_id) do
      nil ->
        {:error, :not_found}

      %GameSession{} = session ->
        turn_number = next_turn_number(session_id)

        {result, steps} =
          Steps.collect(fn ->
            player_action = PlayerAction.decode(player_action_map)
            run_steps(session, turn_number, raw_action, player_action, opts)
          end)

        Steps.record(steps, session_id, turn_number, Tags.for_world(session.world_state))
        finish(result, session_id, turn_number, started)
    end
  end

  defp run_steps(session, turn_number, raw_action, player_action, gm_opts) do
    {handler, mechanical, ruled} =
      Steps.time(:rules, fn -> resolve_rules(session, player_action) end)

    # Prototype, NPC_REACTIONS=on: Jev gut reactions of the NPCs present, before
    # the GM call (on the critical path, short timeout). Moods carry over in
    # world_state["npc_moods"]; this turn's reactions go to the per-turn prompt.
    # Prototype, WORLD_AGENTS=on: the agents relevant to this turn and their facts.
    agents = world_agents(session, ruled)
    {price_lines, priced} = world_prices(agents, session, ruled, raw_action, player_action)
    {reactions, board} = npc_reactions(session, priced, turn_number, raw_action, mechanical)
    premises = premise_findings(session, board, raw_action, turn_number)

    {gm_context, messages} =
      Steps.time(:prompt, fn ->
        gm_context =
          %{session | world_state: board.world}
          |> Context.build_gm_context()
          |> Map.put(:npc_reactions, reactions)
          |> Map.put(:world_facts, agents)
          |> Map.put(:price_lines, price_lines)
          |> Map.put(:moved_from, moved_from(session.world_state, board.world))
          |> Map.put(:premise_findings, premises)
          |> put_rest_growth(session.world_state, handler, mechanical, board)
          |> put_player_request(gm_opts[:gm_note])

        {gm_context,
         Prompts.gm_messages(
           gm_context,
           mechanical,
           gm_action(player_action, gm_opts[:gm_quote]),
           handler,
           turn_number
         )}
      end)

    with {:ok, gm_result} <-
           Steps.time(:gm, fn ->
             LLM.complete_turn(messages, player_action, handler, turn_number,
               session_id: session.id
             )
           end) do
      # Default variant: log the spent gestures the GM used anyway.
      Gestures.log_repeats(gm_result.narrative, Map.get(gm_context, :recent_gestures),
        session: session.id,
        turn: turn_number
      )

      Steps.time(:persist, fn ->
        world_final = apply_allowlisted_patches(board.world, gm_result)

        persist_and_signal(session, world_final, turn_number, raw_action, %{
          handler: handler,
          mechanical: mechanical,
          gm_result: gm_result,
          events: board.events ++ premise_events(premises, board.world),
          sim: board.sim
        })
      end)
      |> tap(fn
        {:ok, _} when agents != [] ->
          WorldAgents.commit(session.id, [], reactions)

          Extract.run_async(
            session.id,
            turn_number,
            raw_action,
            gm_result.narrative,
            agents,
            Tags.for_world(board.world)
          )

        _ ->
          :ok
      end)
    end
  end

  # The location the character left this turn, or nil (the scene block in
  # the GM prompt narrates the move from it).
  defp moved_from(before, after_board) do
    from = Map.get(before || %{}, "location_id")
    if from != Map.get(after_board, "location_id"), do: from
  end

  # Default variant: the claims in the player's words that the session state
  # contradicts (TalesForge.Game.PremiseCheck). They go to the per-turn GM
  # prompt and are recorded on the turn as a `player.false_premise` event. The
  # baseline variant never runs the check, so its prompts stay as they were.
  defp premise_findings(session, board, raw_action, turn_number) do
    if Variant.baseline?(session.world_state || %{}) do
      []
    else
      Steps.time(:premise_check, fn ->
        state =
          PremiseCheck.state(
            session.world_state,
            board.world,
            Map.get(board.sim, :fronts, []),
            won_fights(session.id)
          )

        raw_action
        |> PremiseCheck.check(state)
        |> tap(&log_premises(&1, session.id, turn_number))
      end)
    end
  end

  defp log_premises([], _session_id, _turn_number), do: :ok

  defp log_premises(findings, session_id, turn_number) do
    Logger.info(
      "premise check session=#{session_id} turn=#{turn_number} " <>
        "false_claims=#{inspect(Enum.map(findings, & &1.claim))}"
    )
  end

  defp premise_events(findings, world) do
    findings
    |> PremiseCheck.event(world["world_tick"], world["location_id"])
    |> List.wrap()
  end

  # The player text and narration of each fight the character has won this
  # session, so a kill claim is checked against what was actually fought.
  defp won_fights(session_id) do
    import Ecto.Query

    Turn
    |> where([t], t.game_session_id == ^session_id)
    |> select([t], {t.mechanical_resolution, t.player_action, t.narrative})
    |> Repo.all()
    |> Enum.filter(fn {resolution, _action, _narrative} ->
      PremiseCheck.combat_win?(resolution)
    end)
    |> Enum.map(fn {_resolution, action, narrative} ->
      Enum.join([action || "", narrative || ""], "\n")
    end)
  end

  defp world_agents(session, board) do
    if WorldAgents.enabled?(),
      do: Steps.time(:world_facts, fn -> WorldAgents.collect(session.id, board.world) end),
      else: []
  end

  defp world_prices([], _session, board, _raw_action, _player_action), do: {[], board}

  defp world_prices(agents, session, board, raw_action, player_action) do
    Steps.time(:prices, fn ->
      {world, lines} =
        Prices.resolve(agents, session.world_state, board.world, raw_action, player_action)

      if lines != [],
        do: Logger.info("world prices session=#{session.id} lines=#{inspect(lines)}")

      {lines, %{board | world: world}}
    end)
  end

  defp npc_reactions(session, board, turn_number, raw_action, mechanical) do
    if NpcReactions.enabled?() do
      Steps.time(:npc_reactions, fn ->
        {reactions, world} =
          NpcReactions.react(session.id, board.world, turn_number, raw_action, mechanical)

        {reactions, %{board | world: world}}
      end)
    else
      {[], board}
    end
  end

  # Handler resolution, server mechanics and the board (inventory, clock, move,
  # events, WorldSim, perception): everything decided before narration.
  defp resolve_rules(session, player_action) do
    handler = ActionHandler.resolve(player_action, Variant.of(session.world_state))
    {character, rolled} = apply_mechanics(session.world_state, player_action, handler)
    board = apply_board(session, character, handler, player_action, rolled)
    {handler, %{rolled | improvements: board.improvements, training: board.training}, board}
  end

  # INTENT_JEV=on: the GM's quote replaces overall_intent in the prompt only.
  defp gm_action(player_action, quote) when is_binary(quote) and quote != "",
    do: %PlayerAction{player_action | overall_intent: quote}

  defp gm_action(player_action, _quote), do: player_action

  # Default variant: on a long rest, the improvement attempts the rest
  # resolved and the skills that need reflection first, for the GM's "you wake
  # and feel surer" / "needs reflection" note; on any other turn, a physical
  # skill that improved right away, for the "a little surer at" note.
  defp put_rest_growth(gm_context, world_state, handler, mechanical, board) do
    cond do
      Variant.baseline?(world_state || %{}) ->
        gm_context

      long_rest?(handler) ->
        Map.put(gm_context, :rest_growth, %{
          attempts: mechanical.improvements || [],
          needs_reflection: Map.get(board, :needs_reflection, [])
        })

      Enum.any?(Map.get(board, :turn_growth, []), & &1["improved"]) ->
        Map.put(gm_context, :rest_growth, %{attempts: board.turn_growth, now: true})

      true ->
        gm_context
    end
  end

  defp put_player_request(gm_context, nil), do: gm_context

  defp put_player_request(gm_context, note) when is_binary(note),
    do: Map.put(gm_context, :player_request, note)

  defp finish({:ok, payload}, session_id, turn_number, started) do
    elapsed = System.monotonic_time(:millisecond) - started

    Logger.info(
      "turn completed session=#{session_id} turn=#{turn_number} duration_ms=#{elapsed} llm_source=#{LLM.llm_source(LLM.provider())}"
    )

    SessionPubSub.broadcast(session_id, {:turn_completed, payload})
    {:ok, payload}
  end

  defp finish({:error, reason} = err, session_id, _turn_number, _started) do
    Logger.error("turn processor failed session=#{session_id} reason=#{inspect(reason)}")
    SessionPubSub.broadcast(session_id, {:turn_failed, SessionPubSub.failure_reason(reason)})
    err
  end

  defp finish({:crash, kind, reason, stacktrace}, session_id, turn_number, _started) do
    Logger.error(
      "turn processor crashed session=#{session_id} turn=#{turn_number}\n" <>
        Exception.format(kind, reason, stacktrace)
    )

    SessionPubSub.broadcast(session_id, {:turn_failed, crash_reason(kind, reason)})
    :erlang.raise(kind, reason, stacktrace)
  end

  # What the player and the playtest run see: the kind of crash, no internals
  # (the log has the details).
  defp crash_reason(:error, reason) do
    "crashed: " <> inspect(Exception.normalize(:error, reason, []).__struct__)
  end

  defp crash_reason(kind, _reason), do: "crashed: #{kind}"

  @doc false
  @spec simulate!(GameSession.t(), String.t(), struct(), struct(), struct(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def simulate!(session, raw_action, player_action, handler, mechanical, opts \\ []) do
    gm_result = %GMStructuredResponse{narrative: "ok", context_summary: nil}

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
  @spec apply_board(GameSession.t(), map(), struct(), struct(), struct(), keyword()) :: map()
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

    {world, spent, needs_reflection} =
      world_paused
      |> present_after_tick(sim.people)
      |> Perception.scrub_situation_lines(hidden)
      |> Perception.snapshot_public_facts(sim.fronts ++ sim.people)
      |> Mechanics.apply_vitality(mechanical, opts)
      |> note_reflection(player_action, improvements)
      |> maybe_spend_lp(handler, opts)

    %{
      world: world,
      events: events,
      sim: sim,
      improvements: improvements ++ spent,
      training: training,
      needs_reflection: needs_reflection,
      turn_growth: if(long_rest?(handler), do: [], else: spent)
    }
  end

  # People a front moved this tick (e.g. the Tinjacks walking into the inn) are
  # present this turn, not only from the next one.
  defp present_after_tick(world, []), do: world

  defp present_after_tick(world, people) do
    here = world["location_id"]

    present =
      people
      |> Enum.filter(&(get_in(&1, [:runtime_state, "location_id"]) == here))
      |> Enum.map(& &1.npc_id)
      |> Enum.sort()

    Map.put(world, "present_npcs", present)
  end

  defp apply_pause_or_train(world, session, %{handler: "train"}, player_action, opts) do
    apply_training(world, session, player_action, opts)
  end

  defp apply_pause_or_train(world, _session, handler, _player_action, opts) do
    world_moved = WorldClock.advance(world, ActionHandler.tick_delta(handler))
    {world_improved, improvements} = maybe_attempt_improvements(world_moved, handler, opts)
    {world_improved, improvements, nil}
  end

  # Default variant (decisions 2026-10-09): banked LP (one per failure) are
  # resolved only on a long rest (sleep, or a wait of six hours or more): at
  # most +1 per skill, and the skill's LP are gone afterwards, except for a
  # skill at the reflection level the character did not reflect on, whose LP
  # stay banked (Progression.resolve_rest/3). The "reflecting" list is cleared
  # by the rest, and so is "improved_since_rest". The physical skills in
  # Progression.immediate_skills/0 are resolved at the end of any other turn
  # (Progression.resolve_turn/3, at most +1 per skill per long-rest cycle).
  # The dead learn nothing. The baseline
  # variant spends LP only at a rest (maybe_attempt_improvements/3, the #64
  # rule).
  defp maybe_spend_lp(world, handler, opts) do
    if Variant.baseline?(world) or Mechanics.dead?(world) do
      {world, [], []}
    else
      character = Map.get(world, "character", %{})
      rolls = opts[:improvement_rolls] || %{}
      reflected = Map.get(character, "reflecting", [])

      if long_rest?(handler) do
        {rested, attempts, needs} =
          Progression.resolve_rest(character, rolls, reflected: reflected)

        rested = Map.drop(rested, ["reflecting", "improved_since_rest"])
        {put_in(world, ["character"], rested), attempts, needs}
      else
        {now, attempts} = Progression.resolve_turn(character, rolls, reflected: reflected)
        {put_in(world, ["character"], now), attempts, []}
      end
    end
  end

  # Default variant: skills the player's words reflect on, practise or study
  # (TalesForge.Game.Reflection), and a skill trained with a trainer this turn,
  # are kept in the character's "reflecting" list until the next long rest. The
  # key is only written when there is something to keep.
  defp note_reflection(world, player_action, turn_attempts) do
    if Variant.baseline?(world) do
      world
    else
      trained = for %{"bonus" => _, "skill" => skill} <- turn_attempts, do: skill
      found = Reflection.skills(player_action.overall_intent) ++ trained

      if found == [], do: world, else: update_in(world, ["character"], &add_reflecting(&1, found))
    end
  end

  defp add_reflecting(character, skills) do
    character = character || %{}
    already = Map.get(character, "reflecting", [])
    Map.put(character, "reflecting", Enum.sort(Enum.uniq(already ++ skills)))
  end

  defp long_rest?(%{handler: "wait"} = handler),
    do: handler |> ActionHandler.tick_delta() |> Progression.long_rest?()

  defp long_rest?(_handler), do: false

  defp apply_training(world, session, player_action, opts) do
    action = player_action.action
    npc_id = action.target
    present_ids = Map.get(world, "present_npcs", [])
    npc_def = trainer_personality(session.id, npc_id)
    character = Map.get(world, "character", %{})

    {taught, improvements, training, ticks} =
      Train.apply(
        character,
        npc_def,
        present_ids,
        action,
        Keyword.put(opts, :variant, Variant.of(world))
      )

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

  # Baseline variant only: the #64 rule tries eligible skills at a rest of an
  # hour or more.
  defp maybe_attempt_improvements(world, handler, opts) do
    pause? =
      Variant.baseline?(world) and handler.handler == "wait" and
        ActionHandler.tick_delta(handler) >= WorldClock.ticks_per_hour()

    if pause? do
      rolls = opts[:improvement_rolls] || %{}
      character = Map.get(world, "character", %{})
      {improved, improvements} = Tiered.attempt_improvements(character, rolls)
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
           NPC.apply_gm_updates(session.id, gm_result, Map.get(world_after, "world_tick")),
         # Double-write to `characters` (nothing reads it yet); never fails the turn.
         :ok <- Characters.mirror(session),
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
    Mechanics.apply_server_mechanics(character, player_action, handler, Variant.of(world_state))
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
    move_to(world_state, location_id)
  end

  defp maybe_move(world_state, %{handler: "move", target: target}) when is_binary(target) do
    move_to(world_state, target)
  end

  defp maybe_move(world_state, _), do: world_state

  # Default variant: only to a place that exists (the intent step resolves
  # names and routes; this guards a stale or invented id). Baseline: as before.
  defp move_to(world_state, location_id) do
    if Variant.baseline?(world_state) or World.runtime_location(world_state, location_id) != %{} do
      put_in(world_state, ["character", "location_id"], location_id)
    else
      Logger.warning("move ignored: unknown location_id=#{inspect(location_id)}")
      world_state
    end
  end

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
        |> Ecto.Multi.insert(:turn, turn_cs)
        |> GMReasoning.multi_insert(session.id, Map.get(world_state, "world_tick"), gm_result),
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

  @doc false
  @spec next_turn_number(String.t()) :: pos_integer()
  def next_turn_number(session_id) do
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
