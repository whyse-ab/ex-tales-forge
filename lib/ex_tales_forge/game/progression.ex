defmodule TalesForge.Game.Progression do
  @moduledoc """
  Skill growth for the `"default"` variant: you learn from failure, only in the
  skill you failed, and it sinks in while you sleep (decisions 2026-10-09,
  tales-forge-docs `docs/decisions.md`, superseding the 2026-10-07 "LP spent
  every turn" rule).

  - **Earning:** a failed or partial roll banks one improvement chance (1 LP)
    for that exact skill (`TalesForge.Game.Mechanics`). A success banks
    nothing, and nothing spills to other skills. The linked stat adds no LP.
  - **When:** banked LP are resolved on a long rest, a wait of
    `long_rest_hours` (6) hours or more such as sleep (`long_rest?/1`), not at
    the end of each turn (`resolve_rest/3`, called by
    `TalesForge.Game.TurnProcessor`).
  - **Higher levels need more failures:** one improvement roll costs
    `lp_per_roll/1` banked LP, `ceil(level / 3)` (at least 1): 1 LP up to
    level 3, 2 up to 6, 3 up to 9, 4 up to 12 and so on.
  - **The roll:** 1d20; the skill gains +1 when the roll is **at least 11 and
    at least the skill's level** (`improves?/3`), a chance of
    `(21 − max(level, 11)) / 20`: at most 50%, 5% at 20, nothing past 20
    without a trainer.
  - **At most +1 per skill per night, and nothing carries over:** the rolls
    stop at the first success, and every banked LP of that skill is then gone,
    whether a roll succeeded, all failed, or the LP were too few for one roll.
  - **Reflection from level 10 (`reflection_level`):** a skill at that level or
    higher is only resolved on a rest where the character reflected on it,
    practised or studied it, or trained it with a trainer since the last long
    rest (`TalesForge.Game.Reflection`). Otherwise its LP **stay banked** (the
    one case where LP carry over) and the skill is reported as needing
    reflection, for the GM's note.
  - `immediate_skills/0` lists skills resolved at the end of every turn instead
    of on a rest; it is empty until Fredrik picks any.
  - **Trainers:** a training session is one **free** attempt (no LP) with
    **+5** on the roll (`train/3`), paid for in coin and days
    (`TalesForge.Game.Train`).

  The numbers (`attempt_floor`, `lp_per_roll_divisor`, `reflection_level`,
  `long_rest_hours`) are in `config/config.exs` under
  `config :ex_tales_forge, TalesForge.Game.Progression`.

  The `"baseline"` variant keeps the #64 rule in
  `TalesForge.Game.Progression.Tiered`; `TalesForge.Game.TurnProcessor` picks
  one per session.

  Every roll is one entry in the turn's `mechanical_resolution["improvements"]`
  (`skill`, `roll`, `raw_skill`, `improved`, `lp_spent`, plus `lp_cleared` on
  the last roll of a skill and `bonus` for a trainer), which
  `TalesForge.Playtest.Growth` counts per run.
  """

  alias TalesForge.Game.WorldClock

  @trainer_bonus 5
  @defaults [attempt_floor: 11, lp_per_roll_divisor: 3, reflection_level: 10, long_rest_hours: 6]

  # Skills resolved at the end of the turn instead of waiting for sleep.
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

  @typedoc "What a rest did: the updated sheet, its rolls, and skills that need reflection."
  @type rest_result :: {character(), [attempt()], [String.t()]}

  @doc """
  A growth setting from `config :ex_tales_forge, TalesForge.Game.Progression`
  (`:attempt_floor`, `:lp_per_roll_divisor`, `:reflection_level`,
  `:long_rest_hours`).

      iex> TalesForge.Game.Progression.setting(:reflection_level)
      10
  """
  @spec setting(atom()) :: pos_integer()
  def setting(key) when is_atom(key) do
    :ex_tales_forge
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end

  @doc """
  The chance that one roll raises a skill at `level`:
  `(21 − max(level, 11)) / 20`, between 0 and 0.5.

      iex> Enum.map([0, 1, 7, 11, 12, 20, 21], &TalesForge.Game.Progression.success_chance/1)
      [0.5, 0.5, 0.5, 0.5, 0.45, 0.05, 0.0]
  """
  @spec success_chance(integer()) :: float()
  def success_chance(level) when is_integer(level),
    do:
      ((21 - max(level, setting(:attempt_floor))) / 20)
      |> max(0.0)
      |> min(1.0)
      |> Float.round(4)

  @doc """
  Whether a roll raises the skill: `roll + bonus` must reach both the floor of
  11 and the skill's level, so no roll is a sure thing.

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
      do: roll + bonus >= max(level, setting(:attempt_floor))

  @doc """
  The lowest roll (with any trainer bonus) that can raise a skill.

      iex> TalesForge.Game.Progression.attempt_floor()
      11
  """
  @spec attempt_floor() :: pos_integer()
  def attempt_floor, do: setting(:attempt_floor)

  @doc """
  Banked LP one improvement roll costs at `level`: `ceil(level / 3)`, at least 1.

      iex> Enum.map([0, 3, 4, 6, 7, 10, 13, 16, 19], &TalesForge.Game.Progression.lp_per_roll/1)
      [1, 1, 2, 2, 3, 4, 5, 6, 7]
  """
  @spec lp_per_roll(integer()) :: pos_integer()
  def lp_per_roll(level) when is_integer(level) do
    divisor = setting(:lp_per_roll_divisor)
    max(1, div(level + divisor - 1, divisor))
  end

  @doc """
  Whether a skill at `level` needs reflection before it can grow.

      iex> {TalesForge.Game.Progression.needs_reflection?(9), TalesForge.Game.Progression.needs_reflection?(10)}
      {false, true}
  """
  @spec needs_reflection?(integer()) :: boolean()
  def needs_reflection?(level) when is_integer(level), do: level >= setting(:reflection_level)

  @doc """
  Whether a pause of `ticks` world ticks is a long rest (sleep, or a wait of
  six hours or more), the moment banked LP are resolved.

      iex> TalesForge.Game.Progression.long_rest?(32)
      true
      iex> TalesForge.Game.Progression.long_rest?(4)
      false
  """
  @spec long_rest?(integer()) :: boolean()
  def long_rest?(ticks) when is_integer(ticks),
    do: ticks >= setting(:long_rest_hours) * WorldClock.ticks_per_hour()

  @doc """
  The skills resolved at the end of every turn instead of on a long rest.
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
  Resolves the banked LP of every skill on a long rest, skill by skill
  (alphabetical). Per skill: `div(lp, lp_per_roll(level))` rolls, stopping at
  the first success (+1); then all of the skill's LP are cleared, success or
  not. A skill at `reflection_level` or above that is not in
  `opts[:reflected]` keeps its LP and is returned in the third element.
  `opts[:only]` limits the rest to those skills.

      iex> character = %{"skills" => %{"climbing" => 5}, "learning_points" => %{"climbing" => 5.0}}
      iex> {rested, attempts, []} =
      ...>   TalesForge.Game.Progression.resolve_rest(character, %{"climbing" => [3, 12]})
      iex> {rested["skills"]["climbing"], rested["learning_points"]["climbing"]}
      {6, 0.0}
      iex> Enum.map(attempts, &{&1["roll"], &1["improved"], &1["lp_spent"]})
      [{3, false, 2}, {12, true, 2}]
      iex> List.last(attempts)["lp_cleared"]
      1
  """
  @spec resolve_rest(character(), rolls(), keyword()) :: rest_result()
  def resolve_rest(character, rolls \\ %{}, opts \\ [])
      when is_map(character) and is_map(rolls) and is_list(opts) do
    only = Keyword.get(opts, :only)
    reflected = Keyword.get(opts, :reflected, [])

    character
    |> Map.get("learning_points", %{})
    |> Enum.filter(fn {skill, lp} -> to_float(lp) > 0.0 and (is_nil(only) or skill in only) end)
    |> Enum.map(fn {skill, _lp} -> skill end)
    |> Enum.sort()
    |> Enum.reduce({character, [], [], rolls}, fn skill, {char, acc, pending, rolls} ->
      level = char |> get_in(["skills", skill]) |> to_int()

      if needs_reflection?(level) and skill not in reflected do
        {char, acc, pending ++ [skill], rolls}
      else
        {char, attempts, rolls} = resolve_skill(char, skill, level, rolls)
        {char, acc ++ attempts, pending, rolls}
      end
    end)
    |> then(fn {char, attempts, pending, _rolls} -> {char, attempts, pending} end)
  end

  @doc """
  The banked LP a character holds, per skill (whole LP only).

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

  # Rolls until the first success or until the LP run out, then clears every
  # LP of the skill: nothing carries over to the next night.
  defp resolve_skill(character, skill, level, rolls) do
    lp = character |> get_in(["learning_points", skill]) |> to_float() |> trunc()
    cost = lp_per_roll(level)

    {character, rolled, rolls} =
      roll_until_success(character, skill, div(lp, cost), cost, rolls)

    {put_in(character, ["learning_points", skill], 0.0), mark_cleared(rolled, lp, cost), rolls}
  end

  # The last roll of a skill records the LP left over and cleared with it.
  defp mark_cleared([], _lp, _cost), do: []

  defp mark_cleared(rolled, lp, cost),
    do: List.update_at(rolled, -1, &Map.put(&1, "lp_cleared", lp - cost * length(rolled)))

  defp roll_until_success(character, _skill, 0, _cost, rolls), do: {character, [], rolls}

  defp roll_until_success(character, skill, left, cost, rolls) do
    {roll, rolls} = next_roll(rolls, skill)
    {updated, result} = attempt(character, skill, roll, 0)
    entry = Map.put(result, "lp_spent", cost)

    if entry["improved"] do
      {updated, [entry], rolls}
    else
      {updated, more, rolls} = roll_until_success(updated, skill, left - 1, cost, rolls)
      {updated, [entry | more], rolls}
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
