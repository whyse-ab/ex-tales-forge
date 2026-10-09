defmodule TalesForge.Game.Progression do
  @moduledoc """
  Skill growth for the `"default"` variant: you learn from failure, only in the
  skill you failed, and it sinks in while you sleep (decision 2026-10-09,
  tales-forge-docs `docs/decisions.md`, superseding the 2026-10-07 "LP spent
  every turn" rule).

  - **Earning:** a failed or partial roll banks one improvement chance (1 LP)
    for that exact skill (`TalesForge.Game.Mechanics`). A success banks
    nothing, and nothing spills to other skills. The linked stat adds no LP:
    a high stat helps the character succeed, not learn faster.
  - **When:** banked chances are resolved on a long rest, a wait of
    6 hours or more such as sleep (`long_rest?/1`), not at the end of each
    turn (`TalesForge.Game.TurnProcessor`). Every whole LP is then spent at
    once (`spend_lp/3`); fractions left from older sessions wait.
    `immediate_skills/0` lists the skills that skip the wait and improve at the
    end of the turn instead; it is empty until Fredrik picks any.
  - **The attempt:** roll 1d20; the skill gains +1 when the roll is **at least
    11 and at least the skill's current level** (`improves?/3`). The chance
    is `(21 − max(level, 11)) / 20`: at most 50% (an attempt at level 0 or 1 can
    fail), falling to 5% at 20, and nothing past 20 without a trainer.
  - **Trainers:** a training session is one **free** attempt (no LP) with
    **+5** on the roll (`train/3`), paid for in coin and days
    (`TalesForge.Game.Train`).

  The `"baseline"` variant keeps the #64 rule in
  `TalesForge.Game.Progression.Tiered`; `TalesForge.Game.TurnProcessor` picks
  one per session.

  Every attempt is one entry in the turn's `mechanical_resolution["improvements"]`
  (`skill`, `roll`, `raw_skill`, `improved`, `lp_spent`, plus `bonus` for a
  trainer), which `TalesForge.Playtest.Growth` counts per run.
  """

  alias TalesForge.Game.WorldClock

  @trainer_bonus 5
  @attempt_floor 11
  @long_rest_hours 6

  # Skills that improve at the end of the turn instead of waiting for sleep.
  # Empty on purpose: the candidates are listed in the PR for Fredrik to decide.
  @immediate_skills []

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
  The chance that one attempt raises a skill at `level`:
  `(21 − max(level, 11)) / 20`, between 0 and 0.5.

      iex> Enum.map([0, 1, 7, 11, 12, 20, 21], &TalesForge.Game.Progression.success_chance/1)
      [0.5, 0.5, 0.5, 0.5, 0.45, 0.05, 0.0]
  """
  @spec success_chance(integer()) :: float()
  def success_chance(level) when is_integer(level),
    do: ((21 - max(level, @attempt_floor)) / 20) |> max(0.0) |> min(1.0) |> Float.round(4)

  @doc """
  Whether an attempt roll raises the skill: `roll + bonus` must reach both the
  floor of 11 and the skill's level, so no attempt is a sure thing.

      iex> TalesForge.Game.Progression.improves?(11, 0)
      true
      iex> TalesForge.Game.Progression.improves?(10, 0)
      false
      iex> TalesForge.Game.Progression.improves?(12, 13)
      false
      iex> TalesForge.Game.Progression.improves?(15, 20, 5)
      true
  """
  @spec improves?(integer(), integer(), integer()) :: boolean()
  def improves?(roll, level, bonus \\ 0)
      when is_integer(roll) and is_integer(level) and is_integer(bonus),
      do: roll + bonus >= max(level, @attempt_floor)

  @doc """
  The lowest attempt roll (with any trainer bonus) that can raise a skill.

      iex> TalesForge.Game.Progression.attempt_floor()
      11
  """
  @spec attempt_floor() :: pos_integer()
  def attempt_floor, do: @attempt_floor

  @doc """
  Whether a pause of `ticks` world ticks is a long rest (sleep, or a wait of
  #{@long_rest_hours} hours or more), the moment banked chances are resolved.

      iex> TalesForge.Game.Progression.long_rest?(32)
      true
      iex> TalesForge.Game.Progression.long_rest?(4)
      false
  """
  @spec long_rest?(integer()) :: boolean()
  def long_rest?(ticks) when is_integer(ticks),
    do: ticks >= @long_rest_hours * WorldClock.ticks_per_hour()

  @doc """
  The skills that improve at the end of the turn instead of on a long rest.
  Empty: every skill waits for sleep until Fredrik names exceptions.

      iex> TalesForge.Game.Progression.immediate_skills()
      []
  """
  @spec immediate_skills() :: [String.t()]
  def immediate_skills, do: @immediate_skills

  @doc """
  The bonus a trainer adds to the attempt roll.

      iex> TalesForge.Game.Progression.trainer_bonus()
      5
  """
  @spec trainer_bonus() :: pos_integer()
  def trainer_bonus, do: @trainer_bonus

  @doc """
  Spends every whole Learning Point (banked improvement chance) on improvement
  attempts, one attempt per LP, skill by skill (alphabetical). The level is
  re-read after each attempt, so a second attempt rolls against the raised
  level. Fractions stay. With `only: skills`, just those skills are spent.

      iex> character = %{"skills" => %{"climbing" => 3}, "learning_points" => %{"climbing" => 2.5}}
      iex> {after_spend, attempts} =
      ...>   TalesForge.Game.Progression.spend_lp(character, %{"climbing" => [11, 2]})
      iex> {after_spend["skills"]["climbing"], after_spend["learning_points"]["climbing"]}
      {4, 0.5}
      iex> Enum.map(attempts, &{&1["roll"], &1["raw_skill"], &1["improved"]})
      [{11, 3, true}, {2, 4, false}]
  """
  @spec spend_lp(character(), rolls(), keyword()) :: {character(), [attempt()]}
  def spend_lp(character, rolls \\ %{}, opts \\ [])
      when is_map(character) and is_map(rolls) and is_list(opts) do
    only = Keyword.get(opts, :only)

    character
    |> Map.get("learning_points", %{})
    |> Enum.filter(fn {skill, lp} -> to_float(lp) >= 1.0 and (is_nil(only) or skill in only) end)
    |> Enum.map(fn {skill, _lp} -> skill end)
    |> Enum.sort()
    |> Enum.reduce({character, [], rolls}, fn skill, {char, acc, rolls} ->
      {char, attempts, rolls} = spend_skill(char, skill, rolls)
      {char, acc ++ attempts, rolls}
    end)
    |> then(fn {char, attempts, _rolls} -> {char, attempts} end)
  end

  @doc """
  The banked chances a character holds, per skill (whole LP only), for the
  GM's note and the character page.

      iex> TalesForge.Game.Progression.banked(%{"learning_points" => %{"stealth" => 2.5, "climbing" => 0.5}})
      %{"stealth" => 2}
  """
  @spec banked(character()) :: %{String.t() => pos_integer()}
  def banked(character) when is_map(character) do
    character
    |> Map.get("learning_points", %{})
    |> Enum.map(fn {skill, lp} -> {skill, lp |> to_float() |> trunc()} end)
    |> Enum.filter(fn {_skill, n} -> n > 0 end)
    |> Map.new()
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
