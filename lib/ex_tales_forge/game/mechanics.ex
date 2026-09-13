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
    explicit = action_skill || normalize_skill_name(handler_skill)

    cond do
      explicit -> explicit
      handler in ["move", "inventory", "wait"] -> nil
      true -> nil
    end
  end

  def perform_and_apply(character, skill) do
    normalized = normalize_skill_name(skill) || "insight"
    raw_level = character |> get_in(["skills", normalized]) |> to_int(0)
    effective = effective_skill_level(character, normalized)
    roll = :rand.uniform(20)
    outcome = resolve_outcome(roll, effective, raw_level)
    lp = lp_for_roll(roll, outcome, raw_level)

    learning_points =
      character
      |> Map.get("learning_points", %{})
      |> Map.update(normalized, lp, fn current -> Float.round(to_float(current) + lp, 1) end)

    updated = put_in(character, ["learning_points"], learning_points)

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

  defp no_check_resolution do
    %MechanicalResolution{outcome: "none", notes: "No skill check required."}
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
