defmodule TalesForge.Game.Mechanics do
  @moduledoc """
  Server-side dice rolls and Learning Points.

  A skill check rolls 1d20 against the effective level (raw level plus the
  linked stat's bonus, or the untrained floor at level 0): equal or under
  succeeds.

  What a roll earns depends on the session's variant:

  - **default** (decision 2026-10-09): only a failure or a partial success
    earns, and only for the skill rolled: 1 LP, one banked improvement chance
    (`growth_lp/1`). A success, natural 1 included, earns nothing, and the
    linked stat adds nothing. `TalesForge.Game.Progression` resolves the
    banked chances on a long rest.
  - **baseline:** the #64 rule. Failure 1, success 0.5, natural 20 2, natural 1
    1, plus the linked stat's bonus `(stat − 10) div 4` (`lp_stat_bonus/1`),
    spent by `TalesForge.Game.Progression.Tiered`.

  Failures are counted in `learning_failures` in both; only the baseline
  variant's rule reads them.

  Vitality (wounds, down, death rolls) is here too.
  """

  alias TalesForge.Game.Schemas.{HandlerResult, MechanicalResolution, PlayerAction}

  @skill_stat %{
    "melee_combat" => "STR",
    "ranged_combat" => "DEX",
    "unarmed_combat" => "STR",
    "tactics" => "INT",
    "dodge" => "DEX",
    "stealth" => "DEX",
    "lockpicking" => "DEX",
    "climbing" => "STR",
    "persuasion" => "CHA",
    "deception" => "CHA",
    "intimidation" => "CHA",
    "insight" => "WIS",
    "etiquette" => "CHA",
    "survival" => "CON",
    "tracking" => "WIS",
    "history" => "INT",
    "arcana" => "INT"
  }

  @lp_stat_bonus_max 2

  @action_skill_hints [
    {~r/\b(sneak|hide|stealth)\b/i, "stealth"},
    {~r/\b(ask|talk|persuad|convinc|greet|barter)\b/i, "persuasion"},
    {~r/\b(lie|bluff|deceiv)\b/i, "deception"},
    {~r/\b(intimidat|threaten|menace)\b/i, "intimidation"},
    {~r/\b(look|examine|study|read|search|inspect)\b/i, "insight"},
    {~r/\b(fight|attack|strike|swing|stab)\b/i, "melee_combat"},
    {~r/\b(shoot|aim|bow|arrow)\b/i, "ranged_combat"},
    {~r/\b(climb|scale)\b/i, "climbing"},
    {~r/\b(track|follow trail)\b/i, "tracking"}
  ]

  # Verbs that mean a real check: someone resists, something is hidden, or
  # failing costs something. Ordinary talk ("ask", "greet", "tell") and
  # looking around are not here: they get no roll (decision 2026-10-07).
  @check_skill_hints [
    {~r/\b(sneak|hide|stealth)\b/i, "stealth"},
    {~r/\b(persuad\w*|convinc\w*|barter|haggle)\b/i, "persuasion"},
    {~r/\b(lie|bluff|deceiv\w*)\b/i, "deception"},
    {~r/\b(intimidat\w*|threaten\w*|menac\w*)\b/i, "intimidation"},
    {~r/\b(search|inspect|examine)\b/i, "insight"},
    {~r/\b(fight|attack|strike|swing|stab)\b/i, "melee_combat"},
    {~r/\b(shoot|aim|bow|arrow)\b/i, "ranged_combat"},
    # "scale" only as a verb with something to go up: "silver to the scale"
    # in Paul's speech to Rusk rolled climbing (run 3f7777a6, turn 7).
    {~r/\b(?:climb(?:s|ing)?|scal(?:e|es|ing) (?:the|a|an|that|this|those|its|his|her|up|down))\b/i,
     "climbing"},
    {~r/\b(track|follow trail)\b/i, "tracking"},
    {~r/\b(pick the lock|pick a lock|lockpick\w*)\b/i, "lockpicking"}
  ]

  # Fight verbs and their skill. When a text names several (loose an arrow,
  # then draw a knife), the first one in the text decides.
  @combat_skill_hints [
    {~r/\b(punch\w*|kick\w*|tackl\w*|grappl\w*|wrestl\w*|headbutt\w*|fists?)\b/i,
     "unarmed_combat"},
    {~r/\b(shoot\w*|aim(?:s|ing)? at|nock\w*|draw(?:s|ing)? (?:my |the |his |her )?bow|loos(?:e|es|ing) (?:an |another |my |a |the |two |more )?(?:arrow|shaft|bolt)s?|fir(?:e|es|ing) (?:an |another |my |a |the |two |more )?(?:arrow|shaft|bolt)s?|fir(?:e|es|ing) at|hurl(?:s|ing)?|throw(?:s|ing)? (?:my |the |a )?(?:knife|dagger|spear|axe|hatchet))\b/i,
     "ranged_combat"},
    {~r/\b(fight\w*|attack\w*|strike|strikes|striking|swing\w*|stab\w*|lunge\w*|slash\w*|thrust\w*|hack\w*|(?<!the )cut(?:s|ting)? (?:at|down)|charg(?:e|es|ing)|club\w*|bash\w*|hit|hits|kill\w*|slay\w*|parr(?:y|ies|ying)|disarm\w*|take (?:down|out))\b/i,
     "melee_combat"}
  ]

  @combat_skills ~w(melee_combat ranged_combat unarmed_combat)

  @doc ~S(The stat linked to each skill, e.g. `"stealth" => "DEX"`; unlisted skills use WIS.)
  @spec skill_stat_map() :: %{String.t() => String.t()}
  def skill_stat_map, do: @skill_stat

  @doc """
  A skill name as the sheet keys it: trimmed, lower case, spaces as
  underscores; nil for empty, "none" or "n/a".

      iex> TalesForge.Game.Mechanics.normalize_skill_name(" Melee Combat ")
      "melee_combat"
      iex> TalesForge.Game.Mechanics.normalize_skill_name("none")
      nil
  """
  @spec normalize_skill_name(term()) :: String.t() | nil
  def normalize_skill_name(nil), do: nil

  def normalize_skill_name(skill) do
    cleaned = skill |> to_string() |> String.trim() |> String.downcase()

    if cleaned in ["none", "n/a", ""] do
      nil
    else
      String.replace(cleaned, " ", "_")
    end
  end

  @doc """
  The skill a player's text clearly calls for, or nil when it needs no check.
  Unlike `infer_skill_from_action/1` (the baseline variant) there is no
  fallback: ordinary talk and everyday actions get no roll.

      iex> TalesForge.Game.Mechanics.infer_check_skill("I try to convince her to lower the price")
      "persuasion"
      iex> TalesForge.Game.Mechanics.infer_check_skill("A tankard of your finest ale, please")
      nil
      iex> TalesForge.Game.Mechanics.infer_check_skill("I ask Brenna what the miners talk about")
      nil
      iex> TalesForge.Game.Mechanics.infer_check_skill("I scale the wall behind the stable")
      "climbing"
      iex> TalesForge.Game.Mechanics.infer_check_skill("Why add silver to the scale?")
      nil
  """
  @spec infer_check_skill(String.t()) :: String.t() | nil
  def infer_check_skill(action) when is_binary(action) do
    Enum.find_value(@check_skill_hints, fn {pattern, skill} ->
      if Regex.match?(pattern, action), do: skill
    end)
  end

  @doc """
  Default variant, combat actions only: the skill of the first fight verb in
  the text (melee, ranged or unarmed), or nil when it names none.

      iex> TalesForge.Game.Mechanics.first_combat_skill("I punch him, then grab the knife and stab")
      "unarmed_combat"
      iex> TalesForge.Game.Mechanics.first_combat_skill("I lunge low at the goblin's spear arm")
      "melee_combat"
      iex> TalesForge.Game.Mechanics.first_combat_skill("I loose another arrow, then draw my knife")
      "ranged_combat"
      iex> TalesForge.Game.Mechanics.first_combat_skill("I order a mug of ale")
      nil
  """
  @spec first_combat_skill(String.t()) :: String.t() | nil
  def first_combat_skill(action) when is_binary(action) do
    @combat_skill_hints
    |> Enum.flat_map(fn {pattern, skill} ->
      case Regex.run(pattern, action, return: :index) do
        [{pos, _} | _] -> [{pos, skill}]
        nil -> []
      end
    end)
    |> Enum.min_by(&elem(&1, 0), fn -> nil end)
    |> case do
      {_pos, skill} -> skill
      nil -> nil
    end
  end

  @doc """
  Baseline variant: the skill for a player's text, falling back to `"insight"`
  when no verb matches (so ordinary talk rolls Insight).
  """
  @spec infer_skill_from_action(String.t()) :: String.t()
  def infer_skill_from_action(action) when is_binary(action) do
    Enum.find_value(@action_skill_hints, "insight", fn {pattern, skill} ->
      if Regex.match?(pattern, action), do: skill
    end)
  end

  @doc """
  The server's check for a turn: the skill the action or handler names (none
  for move, inventory, wait and train), rolled with `perform_and_apply/4` under
  the session's `variant` (`"default"` or `"baseline"`). Returns the updated
  character and the resolution.
  """
  @spec apply_server_mechanics(map(), PlayerAction.t(), HandlerResult.t(), String.t()) ::
          {map(), MechanicalResolution.t()}
  def apply_server_mechanics(
        character,
        %PlayerAction{} = player_action,
        %HandlerResult{} = handler,
        variant \\ "default"
      ) do
    action_skill =
      player_action.action.parameters
      |> Map.get("skill")
      |> normalize_skill_name()

    skill = resolve_check_skill(handler.handler, handler.skill, action_skill)

    if is_nil(skill) do
      {character, no_check_resolution()}
    else
      perform_and_apply(character, skill, nil, variant)
    end
  end

  @doc """
  The skill to check: none for the move, inventory, wait and train handlers,
  else the action's skill or the handler's.

      iex> TalesForge.Game.Mechanics.resolve_check_skill("wait", "insight", "stealth")
      nil
      iex> TalesForge.Game.Mechanics.resolve_check_skill("observe", "Insight", nil)
      "insight"
  """
  @spec resolve_check_skill(String.t() | nil, term(), String.t() | nil) :: String.t() | nil
  def resolve_check_skill(handler, handler_skill, action_skill) do
    if handler in ["move", "inventory", "wait", "train"] do
      nil
    else
      action_skill || normalize_skill_name(handler_skill)
    end
  end

  @doc """
  Rolls 1d20 for `skill` (inject `injected_roll` in tests), adds the LP it
  earns under `variant` and counts a failure. LP are only earned here;
  spending them is `TalesForge.Game.Progression` (default) or
  `TalesForge.Game.Progression.Tiered` (baseline).
  """
  @spec perform_and_apply(map(), String.t() | nil, 1..20 | nil, String.t()) ::
          {map(), MechanicalResolution.t()}
  def perform_and_apply(character, skill, injected_roll \\ nil, variant \\ "default") do
    normalized = normalize_skill_name(skill) || "insight"
    raw_level = character |> get_in(["skills", normalized]) |> to_int(0)
    effective = effective_skill_level(character, normalized)
    roll = injected_roll || :rand.uniform(20)
    outcome = resolve_outcome(roll, effective, raw_level)
    baseline? = variant == "baseline"

    lp =
      if baseline?,
        do:
          lp_for_roll(roll, outcome, raw_level) +
            lp_stat_bonus(linked_stat(character, normalized)),
        else: growth_lp(outcome)

    learning_points =
      character
      |> Map.get("learning_points", %{})
      |> add_lp(normalized, lp)

    updated =
      character
      |> Map.put("learning_points", learning_points)
      |> maybe_count_failure(normalized, outcome, roll)

    resolution = %MechanicalResolution{
      skill: normalized,
      outcome: outcome,
      roll: roll,
      effective_skill: effective,
      lp_awarded: lp,
      notes:
        "Rolled #{roll} vs #{normalized} #{effective} (#{base_note(raw_level)}). " <>
          lp_note(lp, baseline?) <> nat_notes(roll)
    }

    {updated, resolution}
  end

  @doc """
  Default variant: the LP a roll's outcome earns for the skill rolled, one
  banked improvement chance for a failure or a partial success and nothing
  for a success.

      iex> Enum.map(~w(failure partial_success success), &TalesForge.Game.Mechanics.growth_lp/1)
      [1.0, 1.0, 0.0]
  """
  @spec growth_lp(String.t()) :: float()
  def growth_lp(outcome) when outcome in ["failure", "partial_success"], do: 1.0
  def growth_lp(_outcome), do: 0.0

  # A success under the default rule earns nothing; the sheet is left as it was.
  defp add_lp(lp_map, _skill, lp) when lp == 0.0, do: lp_map

  defp add_lp(lp_map, skill, lp),
    do: Map.update(lp_map, skill, lp, fn current -> Float.round(to_float(current) + lp, 1) end)

  defp lp_note(lp, true), do: "+#{lp} LP."
  defp lp_note(lp, false) when lp == 0.0, do: "Success: nothing to learn."
  defp lp_note(_lp, false), do: "+1 banked improvement chance (resolved on sleep)."

  @doc """
  Baseline variant: extra Learning Points per roll from the linked stat,
  `(stat − 10) div 4`, from 0 to +2. The default variant adds none.

      iex> Enum.map([8, 13, 14, 18], &TalesForge.Game.Mechanics.lp_stat_bonus/1)
      [0, 0, 1, 2]
  """
  @spec lp_stat_bonus(integer()) :: non_neg_integer()
  def lp_stat_bonus(stat) when is_integer(stat),
    do: (stat - 10) |> div(4) |> max(0) |> min(@lp_stat_bonus_max)

  @doc """
  Wound cap from CON. Minimum 1 (CON 3).
  """
  @spec wound_max(map()) :: pos_integer()
  def wound_max(character) when is_map(character) do
    con = character |> get_in(["stats", "CON"]) |> to_int(10)
    max(1, 3 + div(con - 10, 2))
  end

  @doc ~S(The character's vitality: "ok", "hurt", "down" when wounds reach the cap, or "dead".)
  @spec vitality(map()) :: String.t()
  def vitality(character) when is_map(character) do
    cond do
      Map.get(character, "vitality") == "dead" -> "dead"
      to_int(Map.get(character, "wounds", 0), 0) >= wound_max(character) -> "down"
      to_int(Map.get(character, "wounds", 0), 0) > 0 -> "hurt"
      true -> "ok"
    end
  end

  @doc "True when the character (or the world_state's character) is dead."
  @spec dead?(term()) :: boolean()
  def dead?(world_or_character) when is_map(world_or_character) do
    Map.get(world_or_character, "vitality") == "dead" or
      get_in(world_or_character, ["character", "vitality"]) == "dead"
  end

  def dead?(_), do: false

  @doc """
  Apply at most one wound or one death roll after the perception snapshot.
  Inject `opts[:death_roll]` (1..20) in tests.
  """
  @spec apply_vitality(map(), MechanicalResolution.t() | nil, keyword()) :: map()
  def apply_vitality(world, mechanical, opts \\ []) when is_map(world) do
    character = Map.get(world, "character", %{})
    facts = Map.get(world, "public_facts", [])
    put_in(world, ["character"], apply_character_vitality(character, mechanical, facts, opts))
  end

  defp apply_character_vitality(character, mechanical, facts, opts) do
    character = stamp_wound_max(character)

    cond do
      Map.get(character, "vitality") == "dead" ->
        Map.put(character, "vitality", "dead")

      harm?(mechanical, facts) ->
        apply_harm(character, mechanical, opts)

      true ->
        stamp_vitality(character)
    end
  end

  defp apply_harm(character, mechanical, opts) do
    cap = wound_max(character)
    wounds = character |> Map.get("wounds", 0) |> to_int(0) |> max(0)

    if wounds >= cap do
      resolve_death_roll(character, mechanical, cap, opts)
    else
      new_wounds = wounds + 1

      character
      |> Map.put("wounds", new_wounds)
      |> Map.put("wound_max", cap)
      |> Map.put("vitality", if(new_wounds >= cap, do: "down", else: "hurt"))
    end
  end

  defp resolve_death_roll(character, mechanical, cap, opts) do
    character =
      character
      |> Map.put("wounds", cap)
      |> Map.put("wound_max", cap)

    if fatal_death_roll?(character, opts) do
      character
      |> Map.put("vitality", "dead")
      |> strip_turn_lp(mechanical)
    else
      Map.put(character, "vitality", "down")
    end
  end

  defp fatal_death_roll?(character, opts) do
    con = character |> get_in(["stats", "CON"]) |> to_int(10)
    roll = opts[:death_roll] || :rand.uniform(20)
    roll > div(con, 2)
  end

  defp strip_turn_lp(character, %MechanicalResolution{skill: skill, lp_awarded: lp})
       when is_binary(skill) and is_number(lp) and lp > 0 do
    lp_map = Map.get(character, "learning_points", %{})
    remaining = Float.round(max(to_float(Map.get(lp_map, skill, 0)) - lp, 0.0), 1)
    Map.put(character, "learning_points", Map.put(lp_map, skill, remaining))
  end

  defp strip_turn_lp(character, _), do: character

  defp harm?(mechanical, facts), do: combat_failure?(mechanical) or wound_fact?(facts)

  defp combat_failure?(%MechanicalResolution{outcome: "failure", skill: skill})
       when skill in @combat_skills,
       do: true

  defp combat_failure?(_), do: false

  defp wound_fact?(facts) do
    facts
    |> List.wrap()
    |> Enum.any?(fn
      %{"harm" => "wound"} -> true
      _ -> false
    end)
  end

  defp stamp_wound_max(character), do: Map.put(character, "wound_max", wound_max(character))

  defp stamp_vitality(character) do
    cap = wound_max(character)
    wounds = character |> Map.get("wounds", 0) |> to_int(0) |> max(0) |> min(cap)

    character
    |> Map.put("wounds", wounds)
    |> Map.put("wound_max", cap)
    |> Map.put("vitality", vitality(Map.put(character, "wounds", wounds)))
  end

  defp no_check_resolution do
    %MechanicalResolution{outcome: "none", notes: "No skill check required."}
  end

  defp maybe_count_failure(character, skill, outcome, roll) do
    if outcome == "failure" or roll == 20 do
      failures =
        character
        |> Map.get("learning_failures", %{})
        |> Map.update(skill, 1, fn current -> to_int(current, 0) + 1 end)

      Map.put(character, "learning_failures", failures)
    else
      character
    end
  end

  defp linked_stat(character, skill) do
    character |> get_in(["stats", Map.get(@skill_stat, skill, "WIS")]) |> to_int(10)
  end

  # A trained skill: level plus the linked stat's bonus ((stat - 10) div 2).
  # An untrained one (level 0) uses the untrained floor max(stat div 3, bonus):
  # anyone can try with raw talent (old rules, 2026-10-07).
  defp effective_skill_level(character, skill) do
    base = character |> get_in(["skills", skill]) |> to_int(0)
    stat_key = Map.get(@skill_stat, skill, "WIS")
    stat_value = character |> get_in(["stats", stat_key]) |> to_int(10)

    if base <= 0,
      do: untrained_floor(stat_value),
      else: max(0, base + div(stat_value - 10, 2))
  end

  @doc """
  The untrained roll level for a stat: `max(stat div 3, (stat - 10) div 2)`.
  A skill at level 0 rolls against it; a trained skill uses its level plus the
  stat bonus, so every level counts.

      iex> TalesForge.Game.Mechanics.untrained_floor(12)
      4
      iex> TalesForge.Game.Mechanics.untrained_floor(18)
      6
  """
  @spec untrained_floor(integer()) :: non_neg_integer()
  def untrained_floor(stat) when is_integer(stat),
    do: max(0, max(div(stat, 3), div(stat - 10, 2)))

  defp resolve_outcome(1, _effective, _raw), do: "success"
  defp resolve_outcome(20, _effective, raw) when raw >= 15, do: "partial_success"
  defp resolve_outcome(20, _effective, _raw), do: "failure"
  defp resolve_outcome(roll, effective, _raw) when roll <= effective, do: "success"
  defp resolve_outcome(roll, effective, _raw) when roll <= effective + 3, do: "partial_success"
  defp resolve_outcome(_roll, _effective, _raw), do: "failure"

  defp lp_for_roll(1, _outcome, _raw), do: 1.0
  defp lp_for_roll(20, _outcome, _raw), do: 2.0
  defp lp_for_roll(_roll, "success", _raw), do: 0.5
  defp lp_for_roll(_roll, "partial_success", _raw), do: 1.0
  defp lp_for_roll(_roll, _outcome, _raw), do: 1.0

  defp base_note(raw) when raw <= 0, do: "untrained: stat ÷ 3"
  defp base_note(raw), do: "base #{raw}"

  defp nat_notes(1), do: " Natural 1 — exceptional success."
  defp nat_notes(20), do: " Natural 20."
  defp nat_notes(_), do: ""

  defp to_int(value, _default) when is_integer(value), do: value
  defp to_int(value, _default) when is_float(value), do: trunc(value)

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> default
    end
  end

  defp to_int(_, default), do: default

  defp to_float(value) when is_float(value), do: value
  defp to_float(value) when is_integer(value), do: value * 1.0

  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> 0.0
    end
  end

  defp to_float(_), do: 0.0
end
