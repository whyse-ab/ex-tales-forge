defmodule TalesForge.NPC do
  @moduledoc """
  Per-session NPC runtime: definitions, NpcInstance persistence, memories, presence.

  Core runtime module: Ecto (Schemas.NpcInstance + Repo) for live state;
  definitions come from the pack files in `priv/npcs` (or the pack's own NPCs).
  """

  import Ecto.Query

  alias TalesForge.Characters.{Defaults, Levers}
  alias TalesForge.Game.Features
  alias TalesForge.Game.Pack
  alias TalesForge.Game.Variant
  alias TalesForge.Game.WorldClock
  alias TalesForge.Repo
  alias TalesForge.Schemas.{GameSession, NpcInstance}

  @memory_limit 20
  @memory_context_limit 5

  def refresh_session_world_state(%GameSession{} = session) do
    location_id = Map.get(session.world_state, "location_id", "weary_pilgrim")

    world_state =
      session.world_state
      |> Map.put("present_npcs", sync_present_npcs(session.id, location_id))
      |> Map.put("npc_state", refresh_world_npc_state(session.id))

    session
    |> GameSession.changeset(%{world_state: world_state})
    |> Repo.update()
  end

  @doc """
  Seeds the session's NPC instances from the pack (tin_valley) or the
  `priv/npcs` files. Definitions with a `derive` block get their defaults from
  `TalesForge.Characters.Defaults` (skills on the PC scale, stats, OCEAN), seeded
  per session and NPC; the authored keys stay as overrides.
  """
  def seed_session(%{id: session_id, world_state: world_state}) do
    adventure_id = Map.get(world_state, "adventure_id")
    world_tick = Map.get(world_state, "world_tick", WorldClock.default_start_tick())
    rules = Defaults.rules(adventure_id)

    definitions =
      case adventure_id do
        "tin_valley" ->
          Pack.load("tin_valley", Variant.of(world_state), Features.of(world_state)).npcs

        _ ->
          load_definitions_from_files(rules)
      end

    Enum.each(definitions, fn definition ->
      npc_id = Map.get(definition, "id") || Map.get(definition, :id)

      if npc_id do
        npc_id = to_string(npc_id)
        definition = Defaults.apply(definition, rules, Defaults.seed(session_id, npc_id))
        insert_instance!(session_id, npc_id, definition, world_tick)
      end
    end)

    :ok
  end

  defp load_definitions_from_files(rules) do
    npc_dir()
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.map(fn file ->
      source = "priv/npcs/#{file}"
      definition = load_definition_file(file)
      Levers.validate!(definition, source)
      validate_derive!(definition, rules, source)
      definition
    end)
  end

  defp validate_derive!(%{"derive" => inputs}, rules, source),
    do: Defaults.validate_inputs!(inputs, rules, source)

  defp validate_derive!(_definition, _rules, _source), do: :ok

  def list_instances(session_id) do
    NpcInstance
    |> where([n], n.game_session_id == ^session_id)
    |> Repo.all()
  end

  def get_instance(session_id, npc_id) do
    Repo.get_by(NpcInstance, game_session_id: session_id, npc_id: npc_id)
  end

  def sim_people(session_id) when is_binary(session_id) do
    Enum.map(list_instances(session_id), &to_sim/1)
  end

  def persist_tick_multi(multi, session_id, sim) when is_map(sim) do
    Enum.reduce(Map.get(sim, :people, []), multi, fn person, acc ->
      inst = get_instance(session_id, npc_id(person))

      if inst do
        cs = NpcInstance.changeset(inst, %{runtime_state: runtime(person)})
        Ecto.Multi.update(acc, {:npc, inst.npc_id}, cs)
      else
        acc
      end
    end)
  end

  def record_memory(session_id, npc_id, summary, world_tick)
      when is_binary(session_id) and is_binary(npc_id) and is_binary(summary) do
    trimmed = String.trim(summary)

    if trimmed == "" do
      :ok
    else
      case get_instance(session_id, npc_id) do
        %NpcInstance{} = inst -> persist_memory(inst, trimmed, world_tick)
        nil -> :ok
      end
    end
  end

  def bump_relationship(session_id, npc_id, delta) when is_number(delta) do
    case get_instance(session_id, npc_id) do
      %NpcInstance{} = inst ->
        score = Map.get(inst.runtime_state, "relationship_score", 0.0) + delta
        runtime = Map.put(inst.runtime_state, "relationship_score", score)
        inst |> update_runtime!(runtime)
        {:ok, score}

      nil ->
        {:ok, 0.0}
    end
  end

  def adjust_concern(session_id, npc_id, delta_ticks) when is_integer(delta_ticks) do
    case get_instance(session_id, npc_id) do
      %NpcInstance{} = inst ->
        case Map.get(inst.runtime_state, "current_concern") do
          %{} = concern ->
            waiting = Map.get(inst.runtime_state, "concern_wait_ticks", 0) + delta_ticks
            old_priority = Map.get(concern, "priority", 0)

            initiative_ready? =
              waiting >= 4 and old_priority >= 8 and not initiative_emitted?(inst)

            {waiting, concern} = maybe_escalate_concern(waiting, concern)
            priority = Map.get(concern, "priority", 0)

            runtime =
              inst.runtime_state
              |> Map.put("current_concern", concern)
              |> Map.put("concern_wait_ticks", waiting)
              |> maybe_reset_initiative_emitted(old_priority, priority)

            update_runtime!(inst, runtime)

            {:ok,
             %{
               concern_priority: priority,
               concern_wait_ticks: waiting,
               initiative_pending: initiative_ready? and not initiative_emitted?(inst)
             }}

          _ ->
            :ok
        end

      nil ->
        :ok
    end
  end

  def evaluate_initiative(session_id, npc_id) do
    inst = get_instance(session_id, npc_id)
    priority = concern_priority(inst)
    waiting = concern_wait_ticks(inst)
    emitted? = initiative_emitted?(inst)

    %{
      initiative_pending: waiting >= 4 and priority >= 8 and not emitted?,
      concern_priority: priority
    }
  end

  def initiative_text(%NpcInstance{npc_id: "worried_merchant"} = inst) do
    focus =
      inst.runtime_state
      |> Map.get("current_concern", %{})
      |> Map.get("focus", "the stolen ledger")

    case focus do
      "stolen ledger" ->
        "Henrik Bale steps toward you, voice tight. \"Please — if you've heard who took that ledger, tell me before rumors spread.\""

      "ruined reputation" ->
        "Henrik glances at the crowd, then lowers his voice. \"I can't afford another whisper campaign against my name.\""

      _ ->
        "Henrik Bale wrings his hands. \"It's this business with #{focus} — I need answers.\""
    end
  end

  def initiative_text(%NpcInstance{npc_id: "marta_kellen"} = inst) do
    focus =
      inst.runtime_state
      |> Map.get("current_concern", %{})
      |> Map.get("focus", "the missing ledger")

    case focus do
      "missing ledger" ->
        "Marta wipes the bar and catches your eye. \"That ledger didn't walk off on its own. If you've heard anything, I need to know before sundown.\""

      "unwanted attention in her tavern" ->
        "Marta's voice stays low but firm. \"Too many strangers tonight. Keep your business quiet, or take it outside.\""

      _ ->
        "Marta hesitates, then speaks up. \"Something's been bothering me — #{focus}.\""
    end
  end

  def initiative_text(%NpcInstance{} = inst) do
    name = Map.get(inst.personality || %{}, "name", inst.npc_id)
    "#{name} speaks up, as if a worry has been pressing on them for some time."
  end

  def mark_initiative_emitted(%NpcInstance{} = inst, world_tick) do
    runtime =
      inst.runtime_state
      |> Map.put("initiative_emitted", true)
      |> Map.put("initiative_emitted_at_tick", world_tick)

    update_runtime!(inst, runtime)
    :ok
  end

  def concern_priority(%NpcInstance{} = inst) do
    case Map.get(inst.runtime_state, "current_concern") do
      %{} = concern -> Map.get(concern, "priority", 0)
      _ -> 0
    end
  end

  def concern_priority(nil), do: 0

  def build_agent_state(session_id, npc_id) do
    case get_instance(session_id, npc_id) do
      %NpcInstance{} = inst ->
        %{initiative_pending: pending?, concern_priority: priority} =
          evaluate_initiative(session_id, npc_id)

        %{
          session_id: session_id,
          npc_id: npc_id,
          location_id: Map.get(inst.runtime_state, "location_id"),
          mood: Map.get(inst.runtime_state, "mood", "neutral"),
          relationship_score: Map.get(inst.runtime_state, "relationship_score", 0.0),
          concern_priority: priority,
          concern_wait_ticks: concern_wait_ticks(inst),
          initiative_pending: pending?,
          initiative_emitted: initiative_emitted?(inst),
          last_initiative_tick: Map.get(inst.runtime_state, "initiative_emitted_at_tick"),
          last_interaction_tick: Map.get(inst.runtime_state, "last_interaction_tick")
        }

      nil ->
        %{session_id: session_id, npc_id: npc_id}
    end
  end

  def apply_gm_updates(session_id, gm_result, world_tick) do
    gm_result.npc_memory_updates
    |> List.wrap()
    |> Enum.each(fn update ->
      append_memory(session_id, update, world_tick)
    end)

    :ok
  end

  def sync_present_npcs(session_id, location_id) do
    session_id
    |> list_instances()
    |> Enum.filter(fn inst ->
      Map.get(inst.runtime_state, "location_id") == location_id
    end)
    |> Enum.map(& &1.npc_id)
    |> Enum.sort()
  end

  def stock_map(session_id, npc_ids) when is_list(npc_ids) do
    Enum.reduce(npc_ids, %{}, fn npc_id, acc ->
      case get_instance(session_id, npc_id) do
        %NpcInstance{} = inst ->
          stock = Map.get(inst.runtime_state, "stock", definition_stock(inst))
          Map.put(acc, npc_id, stock)

        nil ->
          acc
      end
    end)
  end

  def persist_stock_updates(_session_id, updates) when map_size(updates) == 0, do: :ok

  def persist_stock_updates(session_id, updates) when is_map(updates) do
    Enum.each(updates, fn {npc_id, stock} ->
      case get_instance(session_id, npc_id) do
        %NpcInstance{} = inst ->
          update_runtime!(inst, Map.put(inst.runtime_state, "stock", stock))

        nil ->
          :ok
      end
    end)

    :ok
  end

  def refresh_world_npc_state(session_id) do
    session_id
    |> list_instances()
    |> Enum.into(%{}, fn inst ->
      {inst.npc_id, display_npc(inst)}
    end)
  end

  def format_gm_sections(session_id, present_npc_ids) do
    present =
      session_id
      |> list_instances()
      |> Enum.filter(&(&1.npc_id in present_npc_ids))

    npc_json =
      present
      |> Enum.map(&prompt_npc_context/1)
      |> Jason.encode!(pretty: true)

    memory_lines =
      present
      |> Enum.flat_map(fn inst ->
        inst
        |> recent_memories()
        |> Enum.map(fn mem ->
          text = Map.get(mem, "what") || Map.get(mem, "summary", "")
          "- #{inst.npc_id}: #{text}"
        end)
      end)

    memory_block =
      if memory_lines == [],
        do: "(none)",
        else: Enum.join(memory_lines, "\n")

    """
    ## Present NPCs (merged definition + runtime)
    #{npc_json}

    ## NPC Memories (recent)
    #{memory_block}
    """
  end

  defp to_sim(%NpcInstance{} = inst) do
    %{
      npc_id: inst.npc_id,
      definition: inst.personality || %{},
      runtime_state: inst.runtime_state || %{}
    }
  end

  defp npc_id(%{npc_id: id}), do: id
  defp npc_id(%{"npc_id" => id}), do: id

  defp runtime(%{runtime_state: state}), do: state
  defp runtime(%{"runtime_state" => state}), do: state

  defp insert_instance!(session_id, npc_id, definition, world_tick) do
    location_id = Map.get(definition, "default_location_id", "weary_pilgrim")

    runtime =
      %{
        "location_id" => location_id,
        "mood" => get_in(definition, ["motivations", "mood"]) || "neutral",
        "relationship_score" => 0.0,
        "memories" => [],
        "since_tick" => world_tick,
        "stock" => seed_stock(definition),
        "resources" => definition["resources"] || %{},
        "public_facts" => definition["public_facts"] || []
      }
      |> maybe_seed_concern_tick(definition, world_tick)

    %NpcInstance{}
    |> NpcInstance.changeset(%{
      game_session_id: session_id,
      npc_id: npc_id,
      personality: definition,
      runtime_state: runtime,
      disposition: 0.0
    })
    |> Repo.insert!(
      on_conflict: :nothing,
      conflict_target: [:game_session_id, :npc_id]
    )
  end

  defp maybe_seed_concern_tick(runtime, definition, world_tick) do
    case get_in(definition, ["motivations", "current_concern"]) do
      %{} = concern ->
        Map.put(runtime, "current_concern", Map.put(concern, "since_tick", world_tick))

      _ ->
        runtime
    end
  end

  defp append_memory(session_id, update, world_tick) when is_map(update) do
    npc_id = Map.get(update, "npc_id") || Map.get(update, :npc_id)
    summary = Map.get(update, "summary") || Map.get(update, :summary)
    record_memory(session_id, npc_id, summary || "", world_tick)
  end

  defp append_memory(_session_id, _update, _world_tick), do: :ok

  defp persist_memory(%NpcInstance{} = inst, summary, world_tick) do
    entry = %{
      "summary" => String.trim(summary),
      "tick" => world_tick,
      "at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    memories =
      inst.runtime_state
      |> Map.get("memories", [])
      |> Kernel.++([entry])
      |> Enum.take(-@memory_limit)

    inst
    |> update_runtime!(Map.put(inst.runtime_state, "memories", memories))

    :ok
  end

  defp update_runtime!(%NpcInstance{} = inst, runtime_state) do
    inst
    |> NpcInstance.changeset(%{runtime_state: runtime_state})
    |> Repo.update!()
  end

  defp display_npc(%NpcInstance{} = inst) do
    definition = inst.personality || %{}

    %{
      "id" => inst.npc_id,
      "name" => Map.get(definition, "name", inst.npc_id),
      "role" => Map.get(definition, "role", "present"),
      "disposition" => Map.get(inst.runtime_state, "mood", "neutral"),
      "concern_priority" => concern_priority(inst),
      "portrait_url" => Map.get(definition, "portrait_url")
    }
  end

  defp prompt_npc_context(%NpcInstance{} = inst) do
    definition = inst.personality || %{}
    runtime = inst.runtime_state || %{}
    concern = runtime["current_concern"] || %{}
    motivations = definition["motivations"] || %{}

    %{
      "id" => inst.npc_id,
      "name" => Map.get(definition, "name", inst.npc_id),
      "role" => Map.get(definition, "role"),
      "appearance" => Map.get(definition, "appearance"),
      "personality" => Map.get(definition, "personality"),
      "personality_traits" => motivations["personality_traits"],
      "mood" => runtime["mood"],
      "relationship_score" => Map.get(runtime, "relationship_score", 0.0),
      "stock" => visible_stock(runtime["stock"] || definition["stock"]),
      "concern_focus" => concern["focus"],
      "memories" => visible_memories(runtime["memories"])
    }
    |> put_hooks(definition["hooks"])
  end

  # Ready-made leads the NPC offers a player (pack data, e.g. Brenna's). Only
  # NPCs that have them get the key, so other NPCs' prompt text is unchanged.
  defp put_hooks(context, [_ | _] = hooks), do: Map.put(context, "hooks", hooks)
  defp put_hooks(context, _hooks), do: context

  defp visible_stock(stock) do
    stock
    |> List.wrap()
    |> Enum.map(&Map.take(&1, ["id", "name", "price_copper", "quantity"]))
  end

  defp visible_memories(memories) do
    memories
    |> List.wrap()
    |> Enum.reject(&(&1["secret"] == true))
    |> Enum.take(-@memory_context_limit)
    |> Enum.map(&Map.take(&1, ["who", "tick", "what", "felt", "summary"]))
  end

  defp recent_memories(%NpcInstance{} = inst) do
    visible_memories(Map.get(inst.runtime_state || %{}, "memories", []))
  end

  defp seed_stock(definition) do
    definition
    |> Map.get("stock", [])
    |> TalesForge.Game.Inventory.normalize_stock()
  end

  defp definition_stock(%NpcInstance{} = inst) do
    inst.personality
    |> Map.get("stock", [])
    |> TalesForge.Game.Inventory.normalize_stock()
  end

  defp load_definition_file(file) do
    npc_dir()
    |> Path.join(file)
    |> File.read!()
    |> Jason.decode!()
  end

  defp maybe_escalate_concern(waiting, concern) when waiting >= 4 do
    priority = min(10, Map.get(concern, "priority", 5) + 1)
    maybe_escalate_concern(waiting - 4, Map.put(concern, "priority", priority))
  end

  defp maybe_escalate_concern(waiting, concern), do: {waiting, concern}

  defp concern_wait_ticks(%NpcInstance{} = inst),
    do: Map.get(inst.runtime_state, "concern_wait_ticks", 0)

  defp concern_wait_ticks(nil), do: 0

  defp initiative_emitted?(%NpcInstance{} = inst),
    do: Map.get(inst.runtime_state, "initiative_emitted", false)

  defp initiative_emitted?(nil), do: false

  defp maybe_reset_initiative_emitted(runtime, old_priority, new_priority)
       when new_priority > old_priority do
    runtime
    |> Map.put("initiative_emitted", false)
    |> Map.delete("initiative_emitted_at_tick")
  end

  defp maybe_reset_initiative_emitted(runtime, _old_priority, _new_priority), do: runtime

  # Resolved at runtime (not a module attribute): in a release priv is not at its build path.
  defp npc_dir, do: Path.join(:code.priv_dir(:ex_tales_forge), "npcs")
end
