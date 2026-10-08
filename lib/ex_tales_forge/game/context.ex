defmodule TalesForge.Game.Context do
  @moduledoc """
  Builds what the intent step and the GM see of a game session.

  - `build_intent_context/1`: the facts the intent step validates the
    player's action against (location, exits, present NPCs, their stock,
    the character, valid skills).
  - `build_gm_context/1`: the GM/scene context (rules, intent context, world
    state, opening scene). The turn adds `:npc_reactions`, `:world_facts`
    and `:price_lines` before `TalesForge.Game.Prompts` turns it into messages.
  - `session_stable_section/1` and `per_turn_section/1`: the two user
    messages. Only the per-turn section may change between turns; see the
    prompt-cache notes in `TalesForge.Game.Prompts`.
  """

  # NON-NEGOTIABLE: Core runtime. Pure Ecto + game logic only.
  # Rules come from Prompts (which may be pack-aware), but state is Ecto.

  alias TalesForge.Game.Mechanics
  alias TalesForge.Game.Movement
  alias TalesForge.Game.Perception
  alias TalesForge.Game.Schemas.MechanicalResolution
  alias TalesForge.Game.Variant
  alias TalesForge.Game.World
  alias TalesForge.GameSessions
  alias TalesForge.NPC
  alias TalesForge.Repo
  alias TalesForge.Schemas.{GameSession, Scene, Turn}

  @doc ~s(The session's adventure id; `"crossroads_ledger"` when the world state has none.)
  @spec adventure_id(map() | nil) :: String.t()
  def adventure_id(world) when is_map(world) do
    Map.get(world, "adventure_id") || "crossroads_ledger"
  end

  def adventure_id(_), do: "crossroads_ledger"

  @doc "The intent context: a string-keyed map of what the player can act on right now."
  @spec build_intent_context(GameSession.t()) :: map()
  def build_intent_context(%GameSession{} = session) do
    world = session.world_state || %{}
    location_id = Map.get(world, "location_id", "weary_pilgrim")
    location = World.runtime_location(world, location_id)
    present_npcs = present_npcs_for(world)
    npc_state = Map.get(world, "npc_state", World.npcs())
    character = Map.get(world, "character", %{})
    npc_stock = NPC.stock_map(session.id, present_npcs)

    %{
      "session_id" => session.id,
      "location_id" => location_id,
      "location_name" => Map.get(world, "location_name", Map.get(location, "name", location_id)),
      "location_blurb" => Map.get(location, "blurb", ""),
      "fixtures" => Map.get(location, "fixtures", []),
      "ground_items" => Map.get(location, "ground_items", []),
      "npc_stock" => npc_stock,
      "exits" => Map.get(location, "exits", []),
      "exit_names" => exit_names(world, Map.get(location, "exits", [])),
      "present_npcs" => present_npcs,
      "npc_details" => npc_details(present_npcs, npc_state),
      "character" => character_summary(character),
      "player_inventory" => Map.get(character, "inventory", []),
      "situation_lines" => Map.get(world, "situation_lines", []),
      "recent_turns" => recent_turns(session.id),
      "valid_skills" => Mechanics.skill_stat_map() |> Map.keys() |> Enum.sort(),
      "variant" => Variant.of(world),
      # For movement (not printed in the prompt): every place, and where the
      # people who are not here are (TalesForge.Game.Movement).
      "places" => Map.get(world, "locations") || World.locations(),
      "npc_locations" => npc_locations(npc_state, present_npcs)
    }
  end

  defp npc_locations(npc_state, present_npcs) when is_map(npc_state) do
    npc_state
    |> Enum.reject(fn {npc_id, _} -> npc_id in present_npcs end)
    |> Enum.filter(fn {_npc_id, detail} -> is_binary(detail["location_id"]) end)
    |> Map.new(fn {npc_id, detail} ->
      {npc_id, %{"name" => detail["name"] || npc_id, "location_id" => detail["location_id"]}}
    end)
  end

  defp npc_locations(_npc_state, _present_npcs), do: %{}

  @doc "The intent context as prompt text (location, exits, NPCs and their stock, skills)."
  @spec format_intent_context(map()) :: String.t()
  def format_intent_context(context) do
    exit_lines =
      Enum.map(context["exits"], fn exit_id ->
        "- #{exit_id} (#{Map.get(context["exit_names"], exit_id, exit_id)})"
      end)

    npc_lines =
      Enum.map(context["present_npcs"], fn npc_id ->
        detail = Map.get(context["npc_details"], npc_id, %{})
        mood = Map.get(detail, "disposition", Map.get(detail, "mood", "present"))

        "- #{npc_id}: #{Map.get(detail, "name", npc_id)} (#{Map.get(detail, "role", "present")}, mood: #{mood})"
      end)

    turn_lines =
      Enum.map(context["recent_turns"], fn turn ->
        "- #{turn["action"]} → #{turn["outcome"]}"
      end)

    [
      "Current location: #{context["location_name"]} (#{context["location_id"]})",
      "Location features:",
      context["location_blurb"] || "(none)",
      "Fixtures:",
      Enum.join(context["fixtures"] || [], ", "),
      "Ground items:",
      Jason.encode!(context["ground_items"] || [], pretty: true),
      "Player inventory:",
      Jason.encode!(context["player_inventory"] || [], pretty: true),
      "Situation:",
      Enum.join(context["situation_lines"] || ["(none)"], "\n"),
      "Character:",
      Jason.encode!(context["character"] || %{}, pretty: true),
      "Recent turns:",
      Enum.join(turn_lines ++ ["- none"], "\n"),
      "Available exits:",
      Enum.join(exit_lines ++ ["- none"], "\n"),
      "Present NPCs:",
      Enum.join(npc_lines ++ ["- none"], "\n"),
      "Valid skills: #{Enum.join(context["valid_skills"], ", ")}"
    ]
    |> Enum.join("\n")
  end

  @doc "The GM/scene context for a session (atom-keyed map)."
  @spec build_gm_context(GameSession.t()) :: map()
  def build_gm_context(%GameSession{} = session) do
    intent = build_intent_context(session)
    world = session.world_state || %{}
    adventure_id = Map.get(world, "adventure_id")

    %{
      session_id: session.id,
      rules: TalesForge.Game.Prompts.load_rules(adventure_id, TalesForge.Game.Variant.of(world)),
      intent_context: intent,
      formatted_intent: format_intent_context(intent),
      world_state: world,
      opening_scene: GameSessions.opening_scene(session.id)
    }
  end

  @doc """
  The whole GM/scene context as one flat string: rules, then session-stable
  content, then per-turn state. The LLM receives the same sections as separate
  messages (see `TalesForge.Game.Prompts.gm_messages/5`); this flat view is for
  tests and debugging.
  """
  @spec format_gm_prompt(map()) :: String.t()
  def format_gm_prompt(context) do
    [context.rules, session_stable_section(context), per_turn_section(context)]
    |> join_sections()
  end

  @doc """
  Content that stays the same for the whole session (until the opening scene is
  replaced): the character's fixed sheet, the adventure, and the opening scene
  the player has already heard. Never put per-turn values (coins, wounds,
  inventory, turn numbers, clocks, NPC moods) here: it sits before the per-turn
  state so the prompt cache can reuse it on every turn.
  """
  @spec session_stable_section(map()) :: String.t()
  def session_stable_section(context) do
    [
      character_sheet(context.world_state),
      opening_section(Map.get(context, :opening_scene), context.world_state)
    ]
    |> join_sections()
  end

  @doc "Everything that can change from turn to turn. Always last in the prompt."
  @spec per_turn_section(map()) :: String.t()
  def per_turn_section(context) do
    npc_sections =
      NPC.format_gm_sections(
        context.session_id,
        Map.get(context.intent_context, "present_npcs", [])
      )

    [
      perceived_facts_section(context),
      context.formatted_intent,
      npc_sections,
      TalesForge.World.prompt_section(Map.get(context, :world_facts)),
      TalesForge.World.Prices.prompt_section(Map.get(context, :price_lines)),
      TalesForge.Game.NpcReactions.prompt_section(Map.get(context, :npc_reactions)),
      scene_now_section(context)
    ]
    |> join_sections()
  end

  @doc """
  Default variant: where the character is, who is with them and where the
  others are, plus the move when this turn changed the location
  (`context[:moved_from]`, set by the turn). The GM narrates from this place
  and voices only the people present, so it can't answer Osric as Brenna
  after the character has left the inn. nil for the baseline variant.
  """
  @spec scene_now_section(map()) :: String.t() | nil
  def scene_now_section(context) do
    world = context.world_state || %{}

    if Variant.baseline?(world) do
      nil
    else
      intent = context.intent_context
      here = intent["location_name"] || intent["location_id"]

      [
        "## Scene now",
        "Where: #{here} (#{intent["location_id"]}).",
        "Present: #{present_names(intent)}.",
        elsewhere_line(world, intent),
        moved_line(world, Map.get(context, :moved_from), here),
        "Narrate from this place. Only the people present can speak or act here; anyone else is elsewhere."
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(&(&1 <> "\n"))
    end
  end

  defp present_names(intent) do
    case intent["present_npcs"] do
      [] ->
        "nobody you need to voice"

      ids ->
        Enum.map_join(ids, ", ", fn id ->
          "#{get_in(intent, ["npc_details", id, "name"]) || id} (#{id})"
        end)
    end
  end

  defp elsewhere_line(world, intent) do
    case Enum.sort(Map.get(intent, "npc_locations", %{})) do
      [] ->
        nil

      others ->
        "Elsewhere (not here): " <>
          Enum.map_join(others, "; ", fn {_id, info} ->
            "#{info["name"]} at #{Movement.name(world, info["location_id"])}"
          end) <> "."
    end
  end

  defp moved_line(_world, nil, _here), do: nil

  defp moved_line(world, from, here) do
    "Just now: the character left #{Movement.name(world, from)} for #{here}. " <>
      "Narrate the way and the arrival here; whoever was at #{Movement.name(world, from)} stays there."
  end

  defp join_sections(sections) do
    sections
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n\n---\n\n")
  end

  defp character_sheet(world) do
    world = world || %{}
    character = Map.get(world, "character", %{})

    """
    ## Session (fixed for this session)
    adventure: #{adventure_id(world)}
    character: #{Map.get(character, "name", "unknown")} (#{Map.get(character, "race", "unknown")})
    """
    |> String.trim()
  end

  # Already told to the player before turn 1. Keep it on every GM turn so the
  # model doesn't re-narrate the arrival as if it just happened (humans and bots).
  defp opening_section(nil, _world), do: nil

  defp opening_section(%Scene{} = scene, world) do
    where = if(scene.location_name, do: " (#{scene.location_name})", else: "")

    if Variant.baseline?(world) do
      """
      ## Opening scene#{where} — already told to the player
      Do not rewrite or re-narrate this as if it just happened. The player has
      already heard it; respond to their action from here.

      #{scene.narrative}
      """
    else
      # Not "from here": after the character leaves, this scene is history.
      """
      ## Opening scene#{where} — already told to the player
      This is how the session began. Do not rewrite or re-narrate it. The
      character may have moved on since: "Scene now" in the per-turn state
      says where they are and who is with them, and it wins over this scene.

      #{scene.narrative}
      """
    end
    |> String.trim()
  end

  @doc """
  The server's resolution of the action (skill, roll, outcome and what the GM
  may and may not narrate) as prompt text; empty without a resolution.
  """
  @spec mechanical_bounds(MechanicalResolution.t() | term()) :: String.t()
  def mechanical_bounds(%MechanicalResolution{} = mechanical) do
    skill = mechanical.skill || "none"
    roll = if is_nil(mechanical.roll), do: "none", else: mechanical.roll
    outcome = mechanical.outcome || "none"

    bounds = """

    ## Server resolution (tone bounds only)
    skill: #{skill}
    roll: #{roll}
    outcome: #{outcome}
    """

    case mechanical.training do
      training when training in ["took_place", "declined"] ->
        bounds <> "training: #{training}\n"

      _ ->
        bounds
    end
  end

  def mechanical_bounds(_), do: ""

  defp perceived_facts_section(context) do
    world = context.world_state || %{}

    case Map.fetch(world, "public_facts") do
      {:ok, facts} when is_list(facts) ->
        Perception.format_facts_section(%{"public_facts" => facts})

      _ ->
        session = %GameSession{id: context.session_id, world_state: world}
        Perception.format_facts_section(Perception.visible_world(session))
    end
  end

  defp present_npcs_for(world) do
    present = Map.get(world, "present_npcs")

    cond do
      is_list(present) and present != [] ->
        present

      adventure_id(world) == "tin_valley" ->
        present || []

      true ->
        ["marta_kellen"]
    end
  end

  defp exit_names(world, exits) do
    Enum.into(exits, %{}, fn exit_id ->
      name =
        world
        |> World.runtime_location(exit_id)
        |> Map.get("name", exit_id)

      {exit_id, name}
    end)
  end

  defp npc_details(npc_ids, npc_state) do
    Enum.into(npc_ids, %{}, fn npc_id ->
      detail = Map.get(npc_state, npc_id, %{})
      {npc_id, detail}
    end)
  end

  defp character_summary(character) do
    %{
      "name" => Map.get(character, "name"),
      "vitality" => Map.get(character, "vitality", "ok"),
      "wounds" => Map.get(character, "wounds", 0),
      "wound_max" => Map.get(character, "wound_max", 3),
      "location_id" => Map.get(character, "location_id"),
      "coins" => Map.get(character, "coins", %{}),
      "inventory" => Map.get(character, "inventory", [])
    }
  end

  defp recent_turns(session_id) do
    import Ecto.Query

    Turn
    |> where([t], t.game_session_id == ^session_id)
    |> order_by([t], desc: t.turn_number)
    |> limit(2)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(fn turn ->
      outcome =
        turn.mechanical_resolution
        |> Kernel.||(%{})
        |> Map.get("outcome", "none")

      %{"action" => String.slice(turn.player_action, 0, 120), "outcome" => outcome}
    end)
  end
end
