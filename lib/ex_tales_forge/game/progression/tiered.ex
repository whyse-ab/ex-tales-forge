defmodule TalesForge.Game.Progression.Tiered do
  @moduledoc """
  The tiered progression rule of ex-tales-forge #64, kept **only for the
  `"baseline"` behaviour variant** (`TalesForge.Game.Variant`) so the A/B arm
  plays the game as it was. The default variant uses
  `TalesForge.Game.Progression` (decision 2026-10-07). Delete this module with
  the baseline arm.

  A skill may try to improve once it has the tier's Learning Points (Novice
  0–5: 5, Adept 6–10: 7, Expert 11–15: 10, Master 16+: 15) and at least one
  failure since the last attempt, at a rest or wait of an hour or more
  (`TalesForge.Game.TurnProcessor`) or with a trainer. The improvement roll is
  1d20 plus the tier modifier (Expert −3, Master −5) against the raw level; a
  trainer lowers the target by 5, and Master (16+) fails without one.
  """

  # {highest raw level in the tier, LP to attempt, improvement roll modifier}
  @tiers [{5, 5, 0}, {10, 7, 0}, {15, 10, -3}, {nil, 15, -5}]
  @min_failures 1

  @typedoc "One improvement attempt, as stored in the turn's `improvements`."
  @type attempt :: %{required(String.t()) => term()}

  @doc """
  One improvement 1d20 per eligible skill (at a rest). Inject `rolls` in tests
  (`skill => 1..20`).
  """
  @spec attempt_improvements(map(), %{optional(String.t()) => 1..20}) :: {map(), [attempt()]}
  def attempt_improvements(character, rolls \\ %{}) when is_map(character) and is_map(rolls) do
    lp_map = Map.get(character, "learning_points", %{})
    fail_map = Map.get(character, "learning_failures", %{})

    eligible =
      (Map.keys(lp_map) ++ Map.keys(fail_map))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.filter(&skill_eligible?(character, &1))

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
  @spec attempt_trained_skill(map(), String.t(), %{optional(String.t()) => 1..20}) ::
          {map(), [attempt()]}
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
    raw = character |> get_in(["skills", skill]) |> to_int(0)
    lp = character |> Map.get("learning_points", %{}) |> Map.get(skill, 0) |> to_float()
    failures = character |> Map.get("learning_failures", %{}) |> Map.get(skill, 0) |> to_int(0)
    lp >= lp_threshold(raw) and failures >= @min_failures
  end

  def skill_eligible?(_, _), do: false

  @doc """
  Learning Points a skill needs before it may try to improve, by its raw
  level's tier: Novice (0–5) 5, Adept (6–10) 7, Expert (11–15) 10, Master
  (16+) 15.

      iex> Enum.map([0, 5, 6, 11, 16], &TalesForge.Game.Progression.Tiered.lp_threshold/1)
      [5, 5, 7, 10, 15]
  """
  @spec lp_threshold(integer()) :: pos_integer()
  def lp_threshold(raw) when is_integer(raw), do: raw |> tier() |> elem(1)

  @doc """
  The improvement roll modifier by tier: 0 up to Adept, −3 at Expert (11–15),
  −5 at Master (16+).

      iex> Enum.map([10, 11, 16], &TalesForge.Game.Progression.Tiered.improvement_modifier/1)
      [0, -3, -5]
  """
  @spec improvement_modifier(integer()) :: integer()
  def improvement_modifier(raw) when is_integer(raw), do: raw |> tier() |> elem(2)

  defp tier(raw), do: Enum.find(@tiers, fn {top, _lp, _mod} -> is_nil(top) or raw <= top end)

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
