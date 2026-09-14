defmodule TalesForge.Game.Mechanics do
  @moduledoc """
  Server-side dice rolls and Learning Points (ported from text-forge).
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
    lp = lp_for_roll(roll, outcome, raw_level)

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
      |> Enum.filter(&eligible_skill?(&1, lp_map, fail_map))

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
  One trainer improvement 1d20. Hit if roll > raw - 5. Inject `rolls` in tests.
  """
  def attempt_trained_skill(character, skill, rolls \\ %{})
      when is_map(character) and is_binary(skill) and is_map(rolls) do
    {updated, entry} = attempt_skill(character, skill, rolls, 5)
    {updated, [entry]}
  end

  def skill_eligible?(character, skill) when is_map(character) and is_binary(skill) do
    eligible_skill?(
      skill,
      Map.get(character, "learning_points", %{}),
      Map.get(character, "learning_failures", %{})
    )
  end

  def skill_eligible?(_, _), do: false

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

  defp eligible_skill?(skill, lp_map, fail_map) do
    to_float(Map.get(lp_map, skill, 0)) >= 5.0 and to_int(Map.get(fail_map, skill, 0), 0) >= 3
  end

  defp attempt_skill(character, skill, rolls, target_offset \\ 0) do
    roll = Map.get(rolls, skill) || :rand.uniform(20)
    raw = character |> get_in(["skills", skill]) |> to_int(0)
    improved = roll > raw - target_offset

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

    entry = %{
      "skill" => skill,
      "roll" => roll,
      "raw_skill" => raw,
      "improved" => improved
    }

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
