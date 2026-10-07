defmodule TalesForge.Game.Mechanics do
  @moduledoc """
  Server-side dice rolls and Learning Points (ported from text-forge).

  Progression follows the old game's tiers (`game-system.json` `progression`,
  2026-10-07): a skill can try to improve once it has the tier's Learning
  Points (Novice 0–5: 5, Adept 6–10: 7, Expert 11–15: 10, Master 16+: 15) and
  at least one failure since the last attempt. The improvement roll is 1d20
  plus the tier modifier (Expert −3, Master −5) against the raw level (a
  trainer lowers the target by 5). Each roll's LP gets the linked stat's bonus
  `(stat − 10) div 4`, from 0 to +2.
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

  # {highest raw level in the tier, LP to attempt, improvement roll modifier}
  @tiers [{5, 5, 0}, {10, 7, 0}, {15, 10, -3}, {nil, 15, -5}]
  @min_failures 1
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
    {~r/\b(climb|scale)\b/i, "climbing"},
    {~r/\b(track|follow trail)\b/i, "tracking"},
    {~r/\b(pick the lock|pick a lock|lockpick\w*)\b/i, "lockpicking"}
  ]

  @combat_skills ~w(melee_combat ranged_combat unarmed_combat)

  def skill_stat_map, do: @skill_stat

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
  """
  @spec infer_check_skill(String.t()) :: String.t() | nil
  def infer_check_skill(action) when is_binary(action) do
    Enum.find_value(@check_skill_hints, fn {pattern, skill} ->
      if Regex.match?(pattern, action), do: skill
    end)
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

  def apply_server_mechanics(
        character,
        %PlayerAction{} = player_action,
        %HandlerResult{} = handler
      ) do
    action_skill =
      player_action.action.parameters
      |> Map.get("skill")
      |> normalize_skill_name()

    skill = resolve_check_skill(handler.handler, handler.skill, action_skill)

    if is_nil(skill) do
      {character, no_check_resolution()}
    else
      perform_and_apply(character, skill)
    end
  end

  def resolve_check_skill(handler, handler_skill, action_skill) do
    if handler in ["move", "inventory", "wait", "train"] do
      nil
    else
      action_skill || normalize_skill_name(handler_skill)
    end
  end

  def perform_and_apply(character, skill, injected_roll \\ nil) do
    normalized = normalize_skill_name(skill) || "insight"
    raw_level = character |> get_in(["skills", normalized]) |> to_int(0)
    effective = effective_skill_level(character, normalized)
    roll = injected_roll || :rand.uniform(20)
    outcome = resolve_outcome(roll, effective, raw_level)
    lp = lp_for_roll(roll, outcome, raw_level) + lp_stat_bonus(linked_stat(character, normalized))

    learning_points =
      character
      |> Map.get("learning_points", %{})
      |> Map.update(normalized, lp, fn current -> Float.round(to_float(current) + lp, 1) end)

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
        "Rolled #{roll} vs #{normalized} #{effective} (base #{raw_level}). +#{lp} LP." <>
          nat_notes(roll)
    }

    {updated, resolution}
  end

  @doc """
  One improvement 1d20 per eligible skill. Inject `rolls` in tests (`skill => 1..20`).
  """
  def attempt_improvements(character, rolls \\ %{}) when is_map(character) and is_map(rolls) do
    lp_map = Map.get(character, "learning_points", %{})
    fail_map = Map.get(character, "learning_failures", %{})

    eligible =
      (Map.keys(lp_map) ++ Map.keys(fail_map))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.filter(&eligible_skill?(character, &1))

    Enum.reduce(eligible, {character, []}, fn skill, {char, acc} ->
      raw = char |> get_in(["skills", skill]) |> to_int(0)

      if raw >= 16 do
        entry = %{
          "skill" => skill,
          "raw_skill" => raw,
          "improved" => false,
          "auto_fail" => true
        }

        {char, acc ++ [entry]}
      else
        {updated, entry} = attempt_skill(char, skill, rolls)
        {updated, acc ++ [entry]}
      end
    end)
  end

  @doc """
  One trainer improvement 1d20. Hit if roll + the tier modifier > raw - 5.
  Inject `rolls` in tests.
  """
  def attempt_trained_skill(character, skill, rolls \\ %{})
      when is_map(character) and is_binary(skill) and is_map(rolls) do
    {updated, entry} = attempt_skill(character, skill, rolls, 5)
    {updated, [entry]}
  end

  @doc """
  Whether a skill may try to improve: its tier's Learning Points
  (`lp_threshold/1`) and at least one failure since the last attempt.
  """
  @spec skill_eligible?(term(), term()) :: boolean()
  def skill_eligible?(character, skill) when is_map(character) and is_binary(skill) do
    eligible_skill?(character, skill)
  end

  def skill_eligible?(_, _), do: false

  @doc """
  Learning Points a skill needs before it may try to improve, by its raw
  level's tier: Novice (0–5) 5, Adept (6–10) 7, Expert (11–15) 10, Master
  (16+) 15.

      iex> Enum.map([0, 5, 6, 11, 16], &TalesForge.Game.Mechanics.lp_threshold/1)
      [5, 5, 7, 10, 15]
  """
  @spec lp_threshold(integer()) :: pos_integer()
  def lp_threshold(raw) when is_integer(raw), do: raw |> tier() |> elem(1)

  @doc """
  The improvement roll modifier by tier: 0 up to Adept, −3 at Expert (11–15),
  −5 at Master (16+).

      iex> Enum.map([10, 11, 16], &TalesForge.Game.Mechanics.improvement_modifier/1)
      [0, -3, -5]
  """
  @spec improvement_modifier(integer()) :: integer()
  def improvement_modifier(raw) when is_integer(raw), do: raw |> tier() |> elem(2)

  @doc """
  Extra Learning Points per roll from the linked stat: `(stat − 10) div 4`,
  from 0 to +2 (a low stat costs nothing, so growth never stalls).

      iex> Enum.map([8, 13, 14, 18], &TalesForge.Game.Mechanics.lp_stat_bonus/1)
      [0, 0, 1, 2]
  """
  @spec lp_stat_bonus(integer()) :: non_neg_integer()
  def lp_stat_bonus(stat) when is_integer(stat),
    do: (stat - 10) |> div(4) |> max(0) |> min(@lp_stat_bonus_max)

  @doc """
  Wound cap from CON. Minimum 1 (CON 3).
  """
  def wound_max(character) when is_map(character) do
    con = character |> get_in(["stats", "CON"]) |> to_int(10)
    max(1, 3 + div(con - 10, 2))
  end

  def vitality(character) when is_map(character) do
    cond do
      Map.get(character, "vitality") == "dead" -> "dead"
      to_int(Map.get(character, "wounds", 0), 0) >= wound_max(character) -> "down"
      to_int(Map.get(character, "wounds", 0), 0) > 0 -> "hurt"
      true -> "ok"
    end
  end

  def dead?(world_or_character) when is_map(world_or_character) do
    Map.get(world_or_character, "vitality") == "dead" or
      get_in(world_or_character, ["character", "vitality"]) == "dead"
  end

  def dead?(_), do: false

  @doc """
  Apply at most one wound or one death roll after the perception snapshot.
  Inject `opts[:death_roll]` (1..20) in tests.
  """
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

  defp eligible_skill?(character, skill) do
    raw = character |> get_in(["skills", skill]) |> to_int(0)
    lp = character |> Map.get("learning_points", %{}) |> Map.get(skill, 0) |> to_float()
    failures = character |> Map.get("learning_failures", %{}) |> Map.get(skill, 0) |> to_int(0)
    lp >= lp_threshold(raw) and failures >= @min_failures
  end

  defp tier(raw), do: Enum.find(@tiers, fn {top, _lp, _mod} -> is_nil(top) or raw <= top end)

  defp linked_stat(character, skill) do
    character |> get_in(["stats", Map.get(@skill_stat, skill, "WIS")]) |> to_int(10)
  end

  defp attempt_skill(character, skill, rolls, target_offset \\ 0) do
    roll = Map.get(rolls, skill) || :rand.uniform(20)
    raw = character |> get_in(["skills", skill]) |> to_int(0)
    modifier = improvement_modifier(raw)
    improved = roll + modifier > raw - target_offset

    prepared =
      character
      |> Map.put_new("skills", %{})
      |> Map.put_new("learning_points", %{})
      |> Map.put_new("learning_failures", %{})

    updated =
      if improved do
        prepared
        |> put_in(["skills", skill], raw + 1)
        |> put_in(["learning_points", skill], 0)
        |> put_in(["learning_failures", skill], 0)
      else
        prepared
        |> put_in(["learning_points", skill], 1.0)
        |> put_in(["learning_failures", skill], 0)
      end

    entry =
      %{"skill" => skill, "roll" => roll, "raw_skill" => raw, "improved" => improved}
      |> then(&if modifier == 0, do: &1, else: Map.put(&1, "modifier", modifier))

    {updated, entry}
  end

  defp effective_skill_level(character, skill) do
    base = character |> get_in(["skills", skill]) |> to_int(0)
    stat_key = Map.get(@skill_stat, skill, "WIS")
    stat_value = character |> get_in(["stats", stat_key]) |> to_int(10)
    bonus = div(stat_value - 10, 2)
    max(0, base + bonus)
  end

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
