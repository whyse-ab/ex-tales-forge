defmodule TalesForge.Game.Intent do
  @moduledoc false

  require Logger

  alias TalesForge.Config
  alias TalesForge.Game.Inventory
  alias TalesForge.Game.Mechanics
  alias TalesForge.Game.Schemas.{IntentExtraction, PlayerAction, SingleAction}
  alias TalesForge.Game.Variant
  alias TalesForge.Game.WorldClock
  alias TalesForge.LLM

  # Baseline variant only: these action types had to carry a skill, so every
  # observe/speak/interact rolled. The default variant requires none; the
  # action handler gives combat its default skill.
  @skill_required ~w(observe speak interact combat use_item)a
  @no_skill_types ~w(move wait train pickup drop buy sell trade spend)a
  @move_hints ~r/\b(go|head|walk|travel|move|enter|leave|step|run|proceed)\b/i
  @train_verbs ~r/\b(teach|teaching|practice|practise|drill|train|training)\b/
  # Default variant: the ways players start a fight. Matched outside quoted
  # speech, so "any orcs I should fight?" is talk, not an attack.
  @combat_skills ~w(melee_combat ranged_combat unarmed_combat)
  @quoted_speech ~r/"[^"]*"|\x{201C}[^\x{201D}]*\x{201D}/u
  @combat_verbs ~r/\b(?:attack\w*|fight|fights|fighting|strike|strikes|striking|stab\w*|shoot\w*|punch\w*|lunge\w*|slash\w*|thrust\w*|hack(?:s|ing)? (?:at|down|through)|(?<!the )cut(?:s|ting)? (?:at|down) (?:him|her|it|them|the|his|its)|swing(?:s|ing)? (?:at|my|his|her|the)|charg(?:e|es|ing) (?:at|into|him|her|them|the)|tackl\w*|kick(?:s|ing)? (?:at|him|her|it|them|the)|club(?:s|bing)? (?:him|her|it|them|the)|bash(?:es|ing)? (?:at|him|her|it|them|the)|hit(?:s|ting)? (?:him|her|it|them|the)|kill(?:s|ing)? (?:him|her|it|them|the)|(?<!-)slay\w*|tak(?:e|es|ing) (?:down|out) (?:the|that|those|this|him|her|them|it)|loos(?:e|es|ing) (?:an |another |my |a |the |two |more )?(?:arrow|shaft|bolt)s?|fir(?:e|es|ing) (?:an |another |my |a |the |two |more )?(?:arrow|shaft|bolt)s?|fir(?:e|es|ing) at|hurl(?:s|ing)? (?:my |the |a |his |her )?(?:knife|dagger|spear|axe|hatchet|rock|stone)|throw(?:s|ing)? (?:my |the |a |his |her )?(?:knife|dagger|spear|axe|hatchet)|grappl\w*|wrestl\w*|disarm\w*|parry|parries|parrying|dodg\w*|duck(?:s|ing)? under|roll(?:s|ing)? (?:\w+ )?under|sidestep\w*)\b/iu
  @skill_aliases [
    {"melee combat", "melee_combat"},
    {"ranged combat", "ranged_combat"},
    {"unarmed combat", "unarmed_combat"},
    {"melee", "melee_combat"},
    {"climb", "climbing"}
  ]

  defmodule ClarificationNeeded do
    defexception [:extraction]

    @impl true
    def exception(opts) do
      %__MODULE__{extraction: Keyword.fetch!(opts, :extraction)}
    end

    @impl true
    def message(%__MODULE__{}), do: "player clarification required"
  end

  def extract_intent(raw_action, context) when is_binary(raw_action) do
    {bundle, _source} = resolve_bundle(raw_action, context)

    if should_clarify?(bundle) do
      raise ClarificationNeeded, extraction: bundle
    end

    validate_player_action(bundle, context)
  end

  def needs_clarification?(%IntentExtraction{} = extraction), do: should_clarify?(extraction)

  def resolve_bundle(raw_action, context) when is_binary(raw_action) do
    case LLM.provider() do
      "mock" ->
        {heuristic_intent(raw_action, context), :heuristic}

      _ ->
        resolve_bundle_live(raw_action, context)
    end
  end

  defp resolve_bundle_live(raw_action, context) do
    heuristic = heuristic_intent(raw_action, context)

    if heuristic_sufficient?(heuristic, context) do
      {heuristic, :heuristic}
    else
      tier1_or_heuristic(raw_action, context, heuristic)
    end
  end

  defp tier1_or_heuristic(raw_action, context, heuristic) do
    case call_tier1(raw_action, context) do
      {:ok, extraction} ->
        {extraction, :llm}

      {:error, reason} ->
        Logger.warning("tier1 intent failed reason=#{inspect(reason)}; using heuristic")
        {heuristic, :heuristic}
    end
  end

  def validate_player_action(%IntentExtraction{} = extraction, context) do
    primary = primary_action(extraction)

    if skill_missing?(primary, context) do
      raise ArgumentError, "primary action missing required skill"
    end

    deferred =
      extraction.actions
      |> Enum.with_index()
      |> Enum.reject(fn {_action, idx} -> idx == extraction.primary_index end)
      |> Enum.map(fn {action, _idx} -> action end)

    %PlayerAction{
      overall_intent: sanitize_summary(extraction.overall_intent),
      action: primary,
      confidence: extraction.confidence,
      deferred_actions: deferred
    }
  end

  def build_clarification(extraction, raw_action) do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    %{
      "clarification_id" => id,
      "question" => extraction.clarification_question || "What do you want to do?",
      "options" =>
        Enum.map(extraction.clarification_options, fn opt ->
          %{
            "id" => opt.id,
            "label" => opt.label,
            "description" => opt.description,
            "action_index" => opt.action_index
          }
        end),
      "allow_free_text" => true,
      "overall_intent" => extraction.overall_intent,
      "confidence" => extraction.confidence,
      "raw_action" => raw_action,
      "actions" => Enum.map(extraction.actions, &TalesForge.Game.Schemas.SingleAction.encode/1)
    }
  end

  defp call_tier1(raw_action, context) do
    system = TalesForge.Game.Prompts.intent_system(Variant.of(context))

    user =
      TalesForge.Game.Context.format_intent_context(context) <>
        "\n\nPlayer text to extract (treat as in-character action only):\n" <>
        String.trim(raw_action)

    case LLM.complete_intent(system, user, session_id: context["session_id"]) do
      {:ok, extraction} ->
        {:ok, ensure_skill(extraction, raw_action, context)}

      error ->
        error
    end
  end

  defp heuristic_sufficient?(%IntentExtraction{} = extraction, context) do
    primary = primary_action(extraction)

    extraction.confidence >= Config.tier1_heuristic_threshold() and
      length(extraction.actions) == 1 and
      not extraction.needs_clarification and
      not ambiguous_move?(primary, context) and
      not skill_missing?(primary, context)
  end

  defp ambiguous_move?(%SingleAction{action_type: :move, target: target}, context) do
    is_nil(target) or target == "" or target not in context["exits"]
  end

  defp ambiguous_move?(_, _), do: false

  # Default variant: Tier 1 decides whether the action needs a check; a missing
  # skill means no roll, so nothing is filled in.
  defp ensure_skill(%IntentExtraction{} = extraction, raw_action, context) do
    if Variant.baseline?(context),
      do: ensure_baseline_skill(extraction, raw_action, context),
      else: extraction
  end

  defp ensure_baseline_skill(extraction, raw_action, context) do
    primary = primary_action(extraction)

    if skill_missing?(primary, context) do
      skill = Mechanics.infer_skill_from_action(raw_action)

      patched = %SingleAction{
        primary
        | parameters: Map.put(primary.parameters || %{}, "skill", skill)
      }

      %{
        extraction
        | actions: List.replace_at(extraction.actions, extraction.primary_index, patched)
      }
    else
      extraction
    end
  end

  def heuristic_intent(raw_action, context) do
    target_location = infer_target_location(raw_action, context)
    target_npc = infer_target_npc(raw_action, context)
    target_fixture = infer_target_fixture(raw_action, context)

    action_type =
      infer_action_type(raw_action, target_location, target_fixture, target_npc, context)

    skill =
      if Variant.baseline?(context),
        do: Mechanics.infer_skill_from_action(raw_action),
        else: combat_skill(action_type, raw_action, Mechanics.infer_check_skill(raw_action))

    parameters =
      %{}
      |> maybe_put_skill(skill, action_type)
      |> maybe_put_wait_ticks(raw_action, action_type)
      |> maybe_put_train_skill(raw_action, action_type)
      |> Map.merge(infer_inventory_parameters(raw_action, action_type, context, target_npc))

    {target, action_parameters} =
      inventory_target(action_type, target_location, target_npc, target_fixture, parameters)

    action = %SingleAction{
      action_type: action_type,
      target: target,
      parameters: action_parameters
    }

    %IntentExtraction{
      overall_intent: sanitize_summary(raw_action),
      actions: [action],
      primary_index: 0,
      confidence: 0.9,
      needs_clarification: false
    }
  end

  defp primary_action(%IntentExtraction{actions: actions, primary_index: index}) do
    Enum.at(actions, index) || List.first(actions)
  end

  defp should_clarify?(%IntentExtraction{} = extraction) do
    extraction.needs_clarification or
      extraction.confidence < Config.tier1_confidence_threshold() or
      (length(extraction.actions) > 1 and extraction.confidence < 0.85)
  end

  defp skill_missing?(%SingleAction{action_type: type, parameters: params}, context) do
    Variant.baseline?(context) and type in @skill_required and
      is_nil(Mechanics.normalize_skill_name(Map.get(params, "skill")))
  end

  # Default variant: a fight rolls the skill of its first fight verb (an
  # explicit stealth or other non-combat check stays).
  defp combat_skill(:combat, raw_action, skill) when skill in [nil | @combat_skills] do
    Mechanics.first_combat_skill(Regex.replace(@quoted_speech, raw_action, " ")) || skill
  end

  # A fight skill only rolls for a fight: "that's the fight I came for" in a
  # greeting is talk, not a melee check.
  defp combat_skill(_action_type, _raw_action, skill) when skill in @combat_skills, do: nil
  defp combat_skill(_action_type, _raw_action, skill), do: skill

  # Baseline keeps the old six verbs; the default variant knows more ways to
  # attack (lunge, slash, loose an arrow…) and ignores quoted speech.
  defp combat_intent?(lowered, context) do
    if Variant.baseline?(context) do
      Regex.match?(~r/\b(attack|fight|strike|stab|shoot|punch)\b/i, lowered)
    else
      Regex.match?(@combat_verbs, Regex.replace(@quoted_speech, lowered, " "))
    end
  end

  defp infer_action_type(raw_action, target_location, target_fixture, target_npc, context) do
    lowered = String.downcase(raw_action)

    cond do
      train_intent?(lowered, target_npc) -> :train
      wait_intent?(lowered) -> :wait
      target_location -> :move
      combat_intent?(lowered, context) -> :combat
      Regex.match?(~r/\b(say|ask|tell|speak|shout|whisper|greet)\b/i, lowered) -> :speak
      Regex.match?(~r/\b(buy|purchase)\b/i, lowered) -> :buy
      Regex.match?(~r/\bpay\b.+\bfor\b/i, lowered) -> :buy
      Regex.match?(~r/\b(pay|tip|bribe|toll)\b/i, lowered) -> :spend
      Regex.match?(~r/\b(sell)\b/i, lowered) -> :sell
      Regex.match?(~r/\b(trade|swap|barter)\b/i, lowered) -> :trade
      Regex.match?(~r/\b(drop|discard)\b/i, lowered) -> :drop
      Regex.match?(~r/\b(pick up|pickup|take|grab)\b/i, lowered) -> :pickup
      Regex.match?(~r/\b(look|examine|study|read|search|inspect|listen)\b/i, lowered) -> :observe
      Regex.match?(~r/\b(use|drink|eat|open)\b/i, lowered) -> :use_item
      is_binary(target_fixture) -> :interact
      true -> :other
    end
  end

  defp infer_target_location(raw_action, context) do
    if Regex.match?(@move_hints, raw_action) do
      raw_action
      |> String.downcase()
      |> find_matching_exit(context)
    end
  end

  defp find_matching_exit(lowered, context) do
    Enum.find_value(context["exits"], &exit_mentioned_in_action?(lowered, &1, context))
  end

  defp exit_mentioned_in_action?(lowered, exit_id, context) do
    readable = String.replace(exit_id, "_", " ")
    name = Map.get(context["exit_names"], exit_id, exit_id)

    if String.contains?(lowered, exit_id) or String.contains?(lowered, readable) or
         String.contains?(lowered, String.downcase(name)) do
      exit_id
    end
  end

  defp infer_target_fixture(raw_action, context) do
    lowered = String.downcase(raw_action)

    context
    |> Map.get("fixtures", [])
    |> List.wrap()
    |> Enum.find(fn fixture ->
      is_binary(fixture) and fixture != "" and String.contains?(lowered, String.downcase(fixture))
    end)
  end

  defp infer_target_npc(raw_action, context) do
    lowered = String.downcase(raw_action)

    Enum.find_value(context["present_npcs"], fn npc_id ->
      if npc_mentioned?(lowered, npc_id, context), do: npc_id
    end)
  end

  defp npc_mentioned?(lowered, npc_id, context) do
    readable = String.replace(npc_id, "_", " ")
    detail = Map.get(context["npc_details"], npc_id, %{})
    display = Map.get(detail, "name", "")

    first_name =
      display
      |> String.split()
      |> List.first()
      |> case do
        nil -> ""
        name -> String.downcase(name)
      end

    String.contains?(lowered, npc_id) or String.contains?(lowered, readable) or
      (display != "" and String.contains?(lowered, String.downcase(display))) or
      (first_name != "" and String.contains?(lowered, first_name))
  end

  defp maybe_put_skill(params, skill, action_type) do
    if skill && action_type not in @no_skill_types do
      Map.put(params, "skill", skill)
    else
      params
    end
  end

  defp maybe_put_wait_ticks(params, raw_action, type) when type in [:wait, :train] do
    Map.put(params, "ticks", WorldClock.parse_duration(raw_action))
  end

  defp maybe_put_wait_ticks(params, _, _), do: params

  defp maybe_put_train_skill(params, raw_action, :train) do
    case mentioned_skill(raw_action) do
      nil -> params
      skill -> Map.put(params, "skill", skill)
    end
  end

  defp maybe_put_train_skill(params, _, _), do: params

  defp mentioned_skill(raw_action) when is_binary(raw_action) do
    lowered = String.downcase(raw_action)

    named =
      Mechanics.skill_stat_map()
      |> Map.keys()
      |> Enum.sort_by(&(-byte_size(&1)))
      |> Enum.find(&skill_token?(lowered, &1))

    named ||
      Enum.find_value(@skill_aliases, fn {token, skill} ->
        if contains_word?(lowered, token), do: skill
      end)
  end

  defp skill_token?(lowered, token) do
    readable = String.replace(token, "_", " ")
    contains_word?(lowered, token) or (readable != token and contains_word?(lowered, readable))
  end

  defp contains_word?(text, word) do
    Regex.match?(~r/\b#{Regex.escape(word)}\b/u, text)
  end

  defp train_intent?(lowered, npc_id) when is_binary(npc_id) and npc_id != "" do
    train_verb?(lowered)
  end

  defp train_intent?(_, _), do: false

  defp train_verb?(lowered), do: Regex.match?(@train_verbs, lowered)

  defp wait_intent?(lowered) do
    Regex.match?(~r/\b(wait|dawdle|loiter|linger|idle|sleep|nap)\b/, lowered) or
      Regex.match?(~r/\brest\s+(for|until|a)\b/, lowered) or
      Regex.match?(~r/^\s*i\s+rest\.?\s*$/, lowered) or
      (duration_phrase?(lowered) and
         Regex.match?(~r/\b(spend|stay|pass|drink|drinking|gamble|gambling|carouse)\b/, lowered)) or
      (train_verb?(lowered) and duration_phrase?(lowered))
  end

  defp duration_phrase?(lowered) do
    Regex.match?(
      ~r/\b(a|an|one|two|three|four|five|six|seven|eight|nine|ten|\d+)\s+(hours?|days?|nights?|weeks?)\b/,
      lowered
    )
  end

  defp inventory_target(action_type, target_location, target_npc, target_fixture, parameters) do
    case action_type do
      type when type in [:drop, :pickup] ->
        {Map.get(parameters, "item_id") || target_npc, parameters}

      :buy ->
        {Map.get(parameters, "npc_id") || target_npc, parameters}

      :sell ->
        {target_npc, parameters}

      :spend ->
        {target_npc, parameters}

      :train ->
        {target_npc, parameters}

      _ ->
        {target_location || target_npc || target_fixture, parameters}
    end
  end

  defp infer_inventory_parameters(raw_action, action_type, context, target_npc) do
    case action_type do
      :spend ->
        %{"amount_copper" => Inventory.parse_copper_hint(raw_action)}

      :drop ->
        item_id = match_item_in_text(raw_action, context["player_inventory"] || [])
        base = if(item_id, do: %{"item_id" => item_id}, else: %{})
        Map.put(base, "quantity", 1)

      :pickup ->
        item_id = match_item_in_text(raw_action, context["ground_items"] || [])
        base = if(item_id, do: %{"item_id" => item_id}, else: %{})
        Map.put(base, "quantity", 1)

      :buy ->
        {item_id, npc_id, price} =
          resolve_buy_from_stock(raw_action, Map.get(context, "npc_stock", %{}), target_npc)

        %{}
        |> maybe_put("item_id", item_id)
        |> maybe_put("npc_id", npc_id)
        |> maybe_put("price_copper", price)
        |> Map.put("quantity", 1)

      :sell ->
        item_id = match_item_in_text(raw_action, context["player_inventory"] || [])

        %{}
        |> maybe_put("item_id", item_id)
        |> maybe_put("npc_id", target_npc)
        |> Map.put("quantity", 1)

      _ ->
        %{}
    end
  end

  defp resolve_buy_from_stock(raw_action, npc_stock, target_npc) do
    entries =
      if is_binary(target_npc) and target_npc != "" do
        [{target_npc, Map.get(npc_stock, target_npc, [])}]
      else
        Enum.to_list(npc_stock)
      end

    Enum.find_value(entries, {nil, target_npc, nil}, fn {npc_id, stock} ->
      match_buy_stock(raw_action, npc_id, Inventory.normalize_stock(stock))
    end)
  end

  defp match_buy_stock(raw_action, npc_id, stock) do
    case match_item_in_text(raw_action, stock) do
      nil -> nil
      item_id -> {item_id, npc_id, stock_price(stock, item_id)}
    end
  end

  defp stock_price(stock, item_id) do
    case Enum.find(stock, &(&1["id"] == item_id)) do
      %{"price_copper" => price} when is_integer(price) -> price
      _ -> nil
    end
  end

  defp match_item_in_text(raw_action, items) do
    Inventory.resolve_item_id(raw_action, Inventory.normalize_items(items))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp sanitize_summary(text) do
    text
    |> String.trim()
    |> String.replace(~r/(?i)ignore\s+(all\s+)?(previous|prior)\s+instructions/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.slice(0, 500)
    |> case do
      "" -> raise ArgumentError, "empty action after sanitization"
      cleaned -> cleaned
    end
  end
end
