defmodule TalesForge.Game.Progression do
  @moduledoc """
  Skill growth: Learning Points buy improvement attempts (decision 2026-10-07,
  tales-forge-docs `docs/decisions.md`, superseding the tiered thresholds of
  ex-tales-forge #64).

  - **1 LP buys one attempt** on the skill that earned it. Roll 1d20; if the
    roll is **equal to or higher than the skill's current level**, the skill
    gains +1. The chance is `(21 − level) / 20`, so growth slows by itself as a
    skill rises and stops at 20 without a trainer.
  - **When:** at the end of every turn, every whole LP a skill holds is spent
    at once (`spend_lp/2`). No rest, no failure count and no threshold is
    needed. Fractions (a success earns 0.5 LP) wait for the next roll.
  - **Trainers:** a training session is one **free** attempt (no LP) with
    **+5** on the roll (`train/3`), paid for in coin and days
    (`TalesForge.Game.Train`).
  - **No tier modifiers:** the Expert −3 and Master −5 roll modifiers are gone;
    the curve already slows growth at high levels.

  This is the `"default"` variant's rule. The `"baseline"` variant keeps the
  #64 rule in `TalesForge.Game.Progression.Tiered`; `TalesForge.Game.TurnProcessor`
  picks one per session.

  Every attempt is one entry in the turn's `mechanical_resolution["improvements"]`
  (`skill`, `roll`, `raw_skill`, `improved`, `lp_spent`, plus `bonus` for a
  trainer), which `TalesForge.Playtest.Growth` counts per run.
  """

  @trainer_bonus 5

  @typedoc "A character sheet map (string keys, as in `world_state[\"character\"]`)."
  @type character :: map()

  @typedoc "One improvement attempt, as stored in the turn's `improvements`."
  @type attempt :: %{required(String.t()) => term()}

  @typedoc """
  Injected d20 results for tests, per skill: one integer for every attempt, or
  a list used in order (then random once it runs out).
  """
  @type rolls :: %{optional(String.t()) => 1..20 | [1..20]}

  @doc """
  The chance that one attempt raises a skill at `level`: `(21 − level) / 20`,
  between 0 and 1.

      iex> Enum.map([0, 3, 5, 7, 12, 20, 21], &TalesForge.Game.Progression.success_chance/1)
      [1.0, 0.9, 0.8, 0.7, 0.45, 0.05, 0.0]
  """
  @spec success_chance(integer()) :: float()
  def success_chance(level) when is_integer(level),
    do: ((21 - level) / 20) |> max(0.0) |> min(1.0) |> Float.round(4)

  @doc """
  Whether an attempt roll raises the skill: `roll + bonus >= level`.

      iex> TalesForge.Game.Progression.improves?(7, 7)
      true
      iex> TalesForge.Game.Progression.improves?(6, 7)
      false
      iex> TalesForge.Game.Progression.improves?(15, 20, 5)
      true
  """
  @spec improves?(integer(), integer(), integer()) :: boolean()
  def improves?(roll, level, bonus \\ 0)
      when is_integer(roll) and is_integer(level) and is_integer(bonus),
      do: roll + bonus >= level

  @doc """
  The bonus a trainer adds to the attempt roll.

      iex> TalesForge.Game.Progression.trainer_bonus()
      5
  """
  @spec trainer_bonus() :: pos_integer()
  def trainer_bonus, do: @trainer_bonus

  @doc """
  Spends every whole Learning Point on improvement attempts, one attempt per
  LP, skill by skill (alphabetical). The level is re-read after each attempt,
  so a second attempt rolls against the raised level. Fractions stay.

      iex> character = %{"skills" => %{"climbing" => 3}, "learning_points" => %{"climbing" => 2.5}}
      iex> {after_spend, attempts} =
      ...>   TalesForge.Game.Progression.spend_lp(character, %{"climbing" => [3, 2]})
      iex> {after_spend["skills"]["climbing"], after_spend["learning_points"]["climbing"]}
      {4, 0.5}
      iex> Enum.map(attempts, &{&1["roll"], &1["raw_skill"], &1["improved"]})
      [{3, 3, true}, {2, 4, false}]
  """
  @spec spend_lp(character(), rolls()) :: {character(), [attempt()]}
  def spend_lp(character, rolls \\ %{}) when is_map(character) and is_map(rolls) do
    character
    |> Map.get("learning_points", %{})
    |> Enum.filter(fn {_skill, lp} -> to_float(lp) >= 1.0 end)
    |> Enum.map(fn {skill, _lp} -> skill end)
    |> Enum.sort()
    |> Enum.reduce({character, [], rolls}, fn skill, {char, acc, rolls} ->
      {char, attempts, rolls} = spend_skill(char, skill, rolls)
      {char, acc ++ attempts, rolls}
    end)
    |> then(fn {char, attempts, _rolls} -> {char, attempts} end)
  end

  @doc """
  One training session: a free attempt (no LP spent) with the trainer bonus on
  the roll. Whether the session may happen at all (trainer present, skill gap,
  fee, vitality) is `TalesForge.Game.Train.qualify/6`.

      iex> character = %{"skills" => %{"persuasion" => 12}, "learning_points" => %{}}
      iex> {trained, attempt} = TalesForge.Game.Progression.train(character, "persuasion", %{"persuasion" => 7})
      iex> {trained["skills"]["persuasion"], attempt["bonus"], attempt["lp_spent"]}
      {13, 5, 0}
  """
  @spec train(character(), String.t(), rolls()) :: {character(), attempt()}
  def train(character, skill, rolls \\ %{})
      when is_map(character) and is_binary(skill) and is_map(rolls) do
    {roll, _rolls} = next_roll(rolls, skill)
    {updated, entry} = attempt(character, skill, roll, @trainer_bonus)
    {updated, entry |> Map.put("bonus", @trainer_bonus) |> Map.put("lp_spent", 0)}
  end

  defp spend_skill(character, skill, rolls) do
    lp = character |> get_in(["learning_points", skill]) |> to_float()

    if lp >= 1.0 do
      {roll, rolls} = next_roll(rolls, skill)
      {updated, entry} = attempt(character, skill, roll, 0)
      remaining = Float.round(lp - 1.0, 1)
      updated = put_in(updated, ["learning_points", skill], remaining)
      {updated, more, rolls} = spend_skill(updated, skill, rolls)
      {updated, [Map.put(entry, "lp_spent", 1) | more], rolls}
    else
      {character, [], rolls}
    end
  end

  defp attempt(character, skill, roll, bonus) do
    level = character |> get_in(["skills", skill]) |> to_int()
    improved = improves?(roll, level, bonus)

    updated =
      character
      |> Map.put_new("skills", %{})
      |> Map.put_new("learning_points", %{})
      |> then(&if improved, do: put_in(&1, ["skills", skill], level + 1), else: &1)

    {updated, %{"skill" => skill, "roll" => roll, "raw_skill" => level, "improved" => improved}}
  end

  defp next_roll(rolls, skill) do
    case Map.get(rolls, skill) do
      [roll | rest] -> {roll, Map.put(rolls, skill, rest)}
      roll when is_integer(roll) -> {roll, rolls}
      _ -> {:rand.uniform(20), rolls}
    end
  end

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)
  defp to_int(_value), do: 0

  defp to_float(value) when is_number(value), do: value * 1.0

  defp to_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> 0.0
    end
  end

  defp to_float(_value), do: 0.0
end
