defmodule TalesForge.CharacterCreation do
  @moduledoc """
  Player character creation on the unified Character: race, class, the stat
  point buy and a typed name. Pure Elixir (no database, no AI), so the creation
  screen and the persona runner drive the same functions.

  * **Labels** (races, classes) come from `TalesForge.Characters.Defaults.rules/1`,
    the global list extended by the world pack.
  * **Creation rules** come from `priv/characters/creation.json`: the 75-point
    buy with 3–18 per stat (`rules/core_mechanics.md`), the race stat choices
    (Human +1 to any two stats, Elf +1 INT or WIS, from `rules/races.md`), the
    background skill points per class, the derivation inputs for a new player
    character and the starting kit.
  * **Point buy:** the base stats (before race) cost one point per stat point
    and may total at most the budget; spending less is allowed. Each base stat
    and each final stat (after the race modifier) must be within the range. A
    race bonus that would push a stat past the maximum is an error, not a
    silent clamp.
  * **Skills** (`creation.json` `skills`, ported from the old game's rules):
    a 25-point skill budget where levels 1–3 cost 1 each and levels 4–5 cost 2
    each, a normal cap of 5 and at least 5 skills. One or two **signature
    skills** may go to 7; levels 6–7 cost 3 each. Free levels come first: the
    class package (its three skills at 3, 2 and 1) and the race bonus (Human +5
    and Half-Elf +3 points to the budget; Elf, Dwarf, Gnome and Halfling fixed
    skill levels). Free levels stack, are subject to the same caps, and any the
    caps cut off come back as points.
  * **Suggestions:** a new draft, or a new class, suggests base stats (the
    suggested base plus the class's stat leanings), race picks (the highest
    eligible base stats) and a spread skill build (`suggest_skills/1`). Parts
    the player has edited are kept.
  * **`finalize/1`** returns a character in the shape of a pack character file
    (sheet plus levers), ready for `TalesForge.GameSessions.create_session/1`.
    OCEAN, Maslow level, concerns and coins come from `Defaults.derive/3` with
    the draft's seed.

  The functions that change a draft return `{:ok, draft}` or
  `{:error, reason}` for input that can never be valid (an unknown label, a stat
  outside the range, a wrong race pick). The budget and a missing name are
  reported by `validate/1`, so a screen can show them while the player
  rebalances.
  """

  alias TalesForge.CharacterCreation.Draft
  alias TalesForge.Characters.Defaults
  alias TalesForge.Game.Mechanics

  @stats ~w(STR DEX CON INT WIS CHA)

  @type rules :: %{required(String.t()) => map()}
  @type error :: {atom(), String.t()}

  # --- rules ------------------------------------------------------------------------

  @doc """
  The rules for creating a character in `adventure_id`: `"labels"` (the
  `Defaults` rules) and `"creation"` (`creation.json`). Raises `ArgumentError`
  if `creation.json` refers to an unknown race or stat. A label without a
  description (one a pack added) is offered with an empty one.
  """
  @spec rules(String.t()) :: rules()
  def rules(adventure_id) when is_binary(adventure_id) do
    labels = Defaults.rules(adventure_id)
    creation = creation_path() |> File.read!() |> Jason.decode!()
    validate_rules!(labels, creation)
    %{"labels" => labels, "creation" => creation}
  end

  @doc """
  What a player chooses from: races and classes (id, description, stat
  modifiers or leanings, race bonus choice, race skill bonus, the class
  package's skills with their free levels), the point-buy limits, the skill
  rules and the skills with their linked stat. Human and "none" come first.
  """
  @spec options(String.t()) :: map()
  def options(adventure_id) when is_binary(adventure_id) do
    %{"labels" => labels, "creation" => creation} = rules(adventure_id)
    descriptions = creation["descriptions"]

    %{
      races:
        labels["races"]
        |> ordered("human")
        |> Enum.map(fn {id, race} ->
          %{
            id: id,
            description: get_in(descriptions, ["races", id]) || "",
            stats: race["stats"],
            choice: race_choice(creation, id),
            skill_bonus: race_bonus(creation, id)
          }
        end),
      classes:
        labels["classes"]
        |> ordered("none")
        |> Enum.map(fn {id, class} ->
          %{
            id: id,
            description: get_in(descriptions, ["classes", id]) || "",
            stats: class["stats"],
            skills: class_skills(class, creation)
          }
        end),
      point_buy: creation["point_buy"],
      skills: Map.delete(creation["skills"], "_doc"),
      skill_list:
        Mechanics.skill_stat_map()
        |> Enum.sort()
        |> Enum.map(fn {id, stat} -> %{id: id, stat: stat} end),
      name_max_length: creation["name_max_length"]
    }
  end

  # --- building a draft -----------------------------------------------------------

  @doc """
  A new draft for `adventure_id`: Human, no class, suggested stats and race
  picks, no name. `opts[:seed_key]` fixes the seed (default: a random UUID).
  """
  @spec new(String.t(), keyword()) :: Draft.t()
  def new(adventure_id, opts \\ []) when is_binary(adventure_id) do
    rules = rules(adventure_id)

    %Draft{adventure_id: adventure_id, seed_key: opts[:seed_key] || Ecto.UUID.generate()}
    |> suggest(rules)
  end

  @doc "Chooses a race. Re-suggests the race picks unless the player set them."
  @spec choose_race(Draft.t(), String.t()) :: {:ok, Draft.t()} | {:error, error()}
  def choose_race(%Draft{} = draft, race) do
    rules = rules(draft.adventure_id)

    if Map.has_key?(rules["labels"]["races"], race) do
      edited = MapSet.delete(draft.edited, :race_picks)
      {:ok, suggest(%{draft | race: race, race_picks: [], edited: edited}, rules)}
    else
      {:error, {:race, "unknown race #{inspect(race)}"}}
    end
  end

  @doc "Chooses a class. Re-suggests the stats and race picks the player hasn't set."
  @spec choose_class(Draft.t(), String.t()) :: {:ok, Draft.t()} | {:error, error()}
  def choose_class(%Draft{} = draft, class) do
    rules = rules(draft.adventure_id)

    if Map.has_key?(rules["labels"]["classes"], class) do
      {:ok, suggest(%{draft | class: class}, rules)}
    else
      {:error, {:class, "unknown class #{inspect(class)}"}}
    end
  end

  @doc """
  Sets one base stat (`"STR"` … `"CHA"`, before the race modifier). The value
  must be an integer within the point-buy range; the budget is checked by
  `validate/1`.
  """
  @spec set_stat(Draft.t(), String.t(), integer()) :: {:ok, Draft.t()} | {:error, error()}
  def set_stat(%Draft{} = draft, stat, value) do
    %{"min" => lo, "max" => hi} = rules(draft.adventure_id)["creation"]["point_buy"]

    cond do
      stat not in @stats ->
        {:error, {:stats, "unknown stat #{inspect(stat)}"}}

      not is_integer(value) or value < lo or value > hi ->
        {:error, {:stats, "#{stat} must be a whole number from #{lo} to #{hi}"}}

      true ->
        {:ok,
         %{
           draft
           | base_stats: Map.put(draft.base_stats, stat, value),
             edited: MapSet.put(draft.edited, :stats)
         }}
    end
  end

  @doc """
  Chooses the stats for a race bonus with a choice: exactly `count` different
  stats from the race's list (Human: two of any; Elf: INT or WIS).
  """
  @spec pick_race_bonus(Draft.t(), [String.t()]) :: {:ok, Draft.t()} | {:error, error()}
  def pick_race_bonus(%Draft{} = draft, picks) when is_list(picks) do
    case race_choice(rules(draft.adventure_id)["creation"], draft.race) do
      nil ->
        {:error, {:race_picks, "#{draft.race} has no stat choice"}}

      %{"count" => count, "from" => from} ->
        cond do
          length(Enum.uniq(picks)) != count or length(picks) != count ->
            {:error, {:race_picks, "choose #{count} different stats for the #{draft.race} bonus"}}

          not Enum.all?(picks, &(&1 in from)) ->
            {:error, {:race_picks, "the #{draft.race} bonus goes to #{Enum.join(from, " or ")}"}}

          true ->
            {:ok, %{draft | race_picks: picks, edited: MapSet.put(draft.edited, :race_picks)}}
        end
    end
  end

  @doc "Sets the typed name (trimmed). Longer than the maximum is an error; empty is caught by `validate/1`."
  @spec set_name(Draft.t(), String.t()) :: {:ok, Draft.t()} | {:error, error()}
  def set_name(%Draft{} = draft, name) when is_binary(name) do
    name = name |> String.trim() |> String.replace(~r/\s+/u, " ")
    max = rules(draft.adventure_id)["creation"]["name_max_length"]

    if String.length(name) > max,
      do: {:error, {:name, "a name has at most #{max} characters"}},
      else: {:ok, %{draft | name: name}}
  end

  @doc """
  Sets a skill to `level` (its final level). The levels above the free ones
  (class package, race bonus) are bought with skill points. A level below the
  free one, above the signature cap, or an unknown skill is an error; the
  budget, the signature count and the minimum number of skills are checked by
  `validate/1`.
  """
  @spec set_skill(Draft.t(), String.t(), integer()) :: {:ok, Draft.t()} | {:error, error()}
  def set_skill(%Draft{} = draft, skill, level) do
    rules = rules(draft.adventure_id)
    %{"signature_cap" => top} = rules["creation"]["skills"]
    free = rules |> free_levels(draft) |> elem(0) |> Map.get(skill, 0)

    cond do
      not Map.has_key?(Mechanics.skill_stat_map(), skill) ->
        {:error, {:skills, "unknown skill #{inspect(skill)}"}}

      not is_integer(level) or level > top ->
        {:error, {:skills, "#{label(skill)} goes up to #{top} at most"}}

      level < free ->
        {:error, {:skills, "#{label(skill)} starts at #{free} for free; it can't go lower"}}

      true ->
        skills =
          if level == free,
            do: Map.delete(draft.skills, skill),
            else: Map.put(draft.skills, skill, level)

        {:ok, %{draft | skills: skills, edited: MapSet.put(draft.edited, :skills)}}
    end
  end

  @doc "Re-suggests a spread skill build and forgets the skill levels the player set."
  @spec suggest_skills(Draft.t()) :: Draft.t()
  def suggest_skills(%Draft{} = draft) do
    rules = rules(draft.adventure_id)

    %{
      draft
      | skills: suggested_skills(draft, rules),
        edited: MapSet.delete(draft.edited, :skills)
    }
  end

  # --- reading a draft ------------------------------------------------------------

  @doc "Points spent on the base stats."
  @spec points_spent(Draft.t()) :: integer()
  def points_spent(%Draft{base_stats: stats}), do: stats |> Map.values() |> Enum.sum()

  @doc "Points left in the budget (negative when overspent)."
  @spec points_left(Draft.t()) :: integer()
  def points_left(%Draft{} = draft),
    do: rules(draft.adventure_id)["creation"]["point_buy"]["budget"] - points_spent(draft)

  @doc "The race's stat modifiers for this draft, with the race picks applied."
  @spec race_modifiers(Draft.t()) :: %{optional(String.t()) => integer()}
  def race_modifiers(%Draft{} = draft), do: race_modifiers(draft, rules(draft.adventure_id))

  @doc "The final stats: base stats plus the race modifiers (not clamped)."
  @spec final_stats(Draft.t()) :: %{optional(String.t()) => integer()}
  def final_stats(%Draft{} = draft), do: final_stats(draft, rules(draft.adventure_id))

  @doc """
  The free skill levels: the class package plus the race's fixed skill
  bonus, after the caps.
  """
  @spec free_skills(Draft.t()) :: %{optional(String.t()) => pos_integer()}
  def free_skills(%Draft{} = draft),
    do: draft.adventure_id |> rules() |> free_levels(draft) |> elem(0)

  @doc "The final skill levels: for each skill the higher of its free level and the level set."
  @spec skill_levels(Draft.t()) :: %{optional(String.t()) => pos_integer()}
  def skill_levels(%Draft{} = draft), do: skill_levels(draft, rules(draft.adventure_id))

  @doc """
  The skill budget: the base budget, plus the race's pool bonus, plus the
  points refunded for free levels the caps cut off.
  """
  @spec skill_budget(Draft.t()) :: non_neg_integer()
  def skill_budget(%Draft{} = draft), do: skill_budget(draft, rules(draft.adventure_id))

  @doc "Skill points spent on the bought levels."
  @spec skill_points_spent(Draft.t()) :: non_neg_integer()
  def skill_points_spent(%Draft{} = draft),
    do: skill_points_spent(draft, rules(draft.adventure_id))

  @doc "Skill points left (negative when overspent)."
  @spec skill_points_left(Draft.t()) :: integer()
  def skill_points_left(%Draft{} = draft) do
    rules = rules(draft.adventure_id)
    skill_budget(draft, rules) - skill_points_spent(draft, rules)
  end

  @doc "The skills above the normal cap (at most two)."
  @spec signature_skills(Draft.t()) :: [String.t()]
  def signature_skills(%Draft{} = draft) do
    rules = rules(draft.adventure_id)
    cap = rules["creation"]["skills"]["cap"]
    for {skill, level} <- Enum.sort(skill_levels(draft, rules)), level > cap, do: skill
  end

  @doc """
  The price of raising a skill from level `from` to level `to` (0 when `to`
  is not above `from`), from `creation.json` `level_costs`.

      iex> TalesForge.CharacterCreation.level_cost("tin_valley", 0, 5)
      7
      iex> TalesForge.CharacterCreation.level_cost("tin_valley", 3, 7)
      10
  """
  @spec level_cost(String.t(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def level_cost(adventure_id, from, to),
    do: cost(rules(adventure_id)["creation"]["skills"], from, to)

  @doc """
  Checks a draft against the rules. Returns `:ok` or `{:error, errors}`, each
  error a `{field, message}` pair (`:name`, `:stats`, `:race_picks`,
  `:skills`).
  """
  @spec validate(Draft.t()) :: :ok | {:error, [error()]}
  def validate(%Draft{} = draft) do
    rules = rules(draft.adventure_id)
    %{"budget" => budget, "min" => lo, "max" => hi} = rules["creation"]["point_buy"]
    spent = points_spent(draft)
    modifiers = race_modifiers(draft, rules)

    errors =
      [
        draft.name == "" && {:name, "type a name"},
        spent > budget && {:stats, "#{budget} points at most; #{spent} spent"},
        race_picks_error(draft, rules)
      ] ++
        Enum.map(final_stats(draft, rules), fn {stat, value} ->
          (value < lo or value > hi) &&
            {:stats,
             "#{stat} would be #{value} after the #{draft.race} modifier " <>
               "(#{signed(Map.get(modifiers, stat, 0))}); it must be #{lo}–#{hi}"}
        end) ++ skill_errors(draft, rules)

    case Enum.filter(errors, & &1) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  @doc """
  The finished character, in the shape of a pack character file: the sheet
  (`id`, `name`, `race`, `class`, `stats`, `skills`, wounds, coins, inventory)
  plus the levers (`ocean`, `maslow`, `concerns`) and `creation` (how it was
  made). The id is `pc_` plus the name as a slug, so it can't clash with an
  NPC. Returns `{:error, errors}` if `validate/1` fails.
  """
  @spec finalize(Draft.t()) :: {:ok, map()} | {:error, [error()]}
  def finalize(%Draft{} = draft) do
    with :ok <- validate(draft) do
      rules = rules(draft.adventure_id)
      creation = rules["creation"]
      slug = slug(draft.name)
      stats = final_stats(draft, rules)

      derived =
        creation["derive"]
        |> Map.merge(%{"race" => draft.race, "class" => draft.class})
        |> Defaults.derive(rules["labels"], Defaults.seed(draft.seed_key, slug))

      {:ok,
       %{
         "id" => slug,
         "name" => draft.name,
         "race" => draft.race,
         "class" => draft.class,
         "stats" => stats,
         "skills" => skill_levels(draft, rules),
         "learning_points" => %{},
         "learning_failures" => %{},
         "wounds" => 0,
         "wound_max" => Mechanics.wound_max(%{"stats" => stats}),
         "vitality" => "ok",
         "coins" => derived["coins"],
         "inventory" => creation["starting_kit"],
         "ocean" => derived["ocean"],
         "maslow" => derived["maslow"],
         "concerns" => derived["concerns"],
         "creation" => %{
           "seed_key" => draft.seed_key,
           "base_stats" => draft.base_stats,
           "race_picks" => draft.race_picks,
           "points_spent" => points_spent(draft),
           "skill_choices" => draft.skills,
           "skill_points_spent" => skill_points_spent(draft, rules),
           "derive" => creation["derive"]
         }
       }}
    end
  end

  @doc """
  The player character id for a typed name: `pc_` plus the name as a
  lowercase ASCII slug (`pc_` alone when nothing is left).
  """
  @spec slug(String.t()) :: String.t()
  def slug(name) when is_binary(name) do
    base =
      name
      |> String.normalize(:nfd)
      |> String.replace(~r/\p{Mn}/u, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 40)

    "pc_" <> base
  end

  # --- internals ------------------------------------------------------------------

  defp suggest(%Draft{} = draft, rules) do
    draft
    |> then(fn d ->
      if MapSet.member?(d.edited, :stats),
        do: d,
        else: %{d | base_stats: suggested_stats(d, rules)}
    end)
    |> then(fn d ->
      if MapSet.member?(d.edited, :race_picks),
        do: d,
        else: %{d | race_picks: suggested_picks(d, rules)}
    end)
    |> then(fn d ->
      if MapSet.member?(d.edited, :skills),
        do: d,
        else: %{d | skills: suggested_skills(d, rules)}
    end)
  end

  defp suggested_stats(draft, rules) do
    %{"min" => lo, "max" => hi} = rules["creation"]["point_buy"]
    base = rules["creation"]["suggested_base"]
    leanings = rules["labels"]["classes"][draft.class]["stats"]

    Map.new(@stats, fn stat ->
      {stat, (base + Map.get(leanings, stat, 0)) |> max(lo) |> min(hi)}
    end)
  end

  defp suggested_picks(draft, rules) do
    case race_choice(rules["creation"], draft.race) do
      nil ->
        []

      %{"count" => count, "from" => from} ->
        from
        |> Enum.sort_by(
          &{-Map.get(draft.base_stats, &1, 0), Enum.find_index(@stats, fn s -> s == &1 end)}
        )
        |> Enum.take(count)
        |> Enum.sort_by(fn s -> Enum.find_index(@stats, &(&1 == s)) end)
    end
  end

  defp race_modifiers(draft, rules) do
    fixed = rules["labels"]["races"][draft.race]["stats"]

    case race_choice(rules["creation"], draft.race) do
      nil ->
        fixed

      %{"amount" => amount, "replaces" => replaces} ->
        without = Map.merge(fixed, replaces, fn _stat, value, replaced -> value - replaced end)

        draft.race_picks
        |> Enum.reduce(without, fn stat, acc -> Map.update(acc, stat, amount, &(&1 + amount)) end)
        |> Map.reject(fn {_stat, value} -> value == 0 end)
    end
  end

  defp final_stats(draft, rules) do
    modifiers = race_modifiers(draft, rules)
    Map.new(@stats, &{&1, Map.get(draft.base_stats, &1, 0) + Map.get(modifiers, &1, 0)})
  end

  defp race_picks_error(draft, rules) do
    case race_choice(rules["creation"], draft.race) do
      %{"count" => count} when length(draft.race_picks) != count ->
        {:race_picks, "choose #{count} stats for the #{draft.race} bonus"}

      _ ->
        false
    end
  end

  defp race_choice(creation, race), do: get_in(creation, ["race_choices", race])

  # The class package: every class skill, at the package's free levels in order.
  defp class_skills(class, creation) do
    package = creation["skills"]["class_package"]

    class["skills"]
    |> Enum.with_index()
    |> Map.new(fn {skill, i} -> {skill, Enum.at(package, i)} end)
  end

  defp race_bonus(creation, race), do: get_in(creation, ["skills", "race_bonuses", race]) || %{}

  # --- skills -----------------------------------------------------------------------

  # Free levels before the caps, in priority order (class package, then race).
  defp free_sources(draft, rules) do
    creation = rules["creation"]
    class = class_skills(rules["labels"]["classes"][draft.class], creation)
    race = Map.get(race_bonus(creation, draft.race), "fixed", %{})
    {Map.merge(class, race, fn _skill, a, b -> a + b end), Map.keys(class) ++ Map.keys(race)}
  end

  # {free levels after the caps, points refunded for the levels cut off}. A free
  # level above the cap makes a signature skill; past the signature cap, or past
  # the signature count (the highest free levels keep it), it is cut and refunded.
  defp free_levels(rules, draft) do
    sk = rules["creation"]["skills"]
    {raw, _order} = free_sources(draft, rules)

    signature =
      raw
      |> Enum.filter(fn {_s, l} -> l > sk["cap"] end)
      |> Enum.sort_by(fn {s, l} -> {-l, s} end)
      |> Enum.take(sk["signature_max"])
      |> MapSet.new(fn {s, _l} -> s end)

    Enum.reduce(raw, {%{}, 0}, fn {skill, level}, {acc, refund} ->
      top = if MapSet.member?(signature, skill), do: sk["signature_cap"], else: sk["cap"]
      kept = min(level, top)
      {Map.put(acc, skill, kept), refund + refund_cost(sk, kept, level)}
    end)
  end

  defp refund_cost(sk, kept, level) do
    costs = sk["level_costs"]
    last = List.last(costs)

    if level > kept,
      do: Enum.sum(for l <- (kept + 1)..level, do: Enum.at(costs, l - 1, last)),
      else: 0
  end

  defp cost(sk, from, to) when to > from,
    do:
      Enum.sum(
        for l <- (from + 1)..to,
            do: Enum.at(sk["level_costs"], l - 1, List.last(sk["level_costs"]))
      )

  defp cost(_sk, _from, _to), do: 0

  defp skill_levels(draft, rules) do
    {free, _refund} = free_levels(rules, draft)

    free
    |> Map.merge(draft.skills, fn _skill, f, set -> max(f, set) end)
    |> Map.reject(fn {_skill, level} -> level <= 0 end)
  end

  defp skill_budget(draft, rules) do
    sk = rules["creation"]["skills"]
    {_free, refund} = free_levels(rules, draft)
    sk["budget"] + Map.get(race_bonus(rules["creation"], draft.race), "pool", 0) + refund
  end

  defp skill_points_spent(draft, rules) do
    sk = rules["creation"]["skills"]
    {free, _refund} = free_levels(rules, draft)

    Enum.reduce(draft.skills, 0, fn {skill, level}, acc ->
      acc + cost(sk, Map.get(free, skill, 0), level)
    end)
  end

  defp skill_errors(draft, rules) do
    sk = rules["creation"]["skills"]
    levels = skill_levels(draft, rules)
    budget = skill_budget(draft, rules)
    spent = skill_points_spent(draft, rules)
    signature = Enum.count(levels, fn {_s, l} -> l > sk["cap"] end)

    [
      spent > budget && {:skills, "#{budget} skill points at most; #{spent} spent"},
      signature > sk["signature_max"] &&
        {:skills,
         "#{sk["signature_max"]} signature skills at most (above #{sk["cap"]}); #{signature} chosen"},
      Enum.any?(levels, fn {_s, l} -> l > sk["signature_cap"] end) &&
        {:skills, "a skill goes up to #{sk["signature_cap"]} at most"},
      map_size(levels) < sk["min_skills"] &&
        {:skills, "choose at least #{sk["min_skills"]} skills; #{map_size(levels)} so far"}
    ]
  end

  # A spread build: the leading skills (class package, race bonus) plus
  # fillers for the highest stats, at least one more than the minimum. Raised
  # lowest first, one level at a time, up to the normal cap; when every one is
  # at the cap and points are left, the next filler joins.
  defp suggested_skills(draft, rules) do
    sk = rules["creation"]["skills"]
    {free, _refund} = free_levels(rules, draft)
    {_raw, sources} = free_sources(draft, rules)
    leading = Enum.uniq(sources)
    fillers = fillers(leading, final_stats(draft, rules))
    {first, rest} = Enum.split(fillers, max(sk["min_skills"] + 1 - length(leading), 0))
    candidates = leading ++ first

    candidates
    |> Map.new(&{&1, Map.get(free, &1, 0)})
    |> raise_lowest(candidates, rest, skill_budget(draft, rules), sk)
    |> Map.reject(fn {skill, level} -> level <= Map.get(free, skill, 0) end)
  end

  defp fillers(leading, stats) do
    Mechanics.skill_stat_map()
    |> Enum.sort_by(fn {skill, stat} -> {-Map.get(stats, stat, 10), skill} end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&(&1 in leading))
  end

  defp raise_lowest(levels, candidates, rest, left, sk) do
    next =
      candidates
      |> Enum.filter(&(levels[&1] < sk["cap"] and cost(sk, levels[&1], levels[&1] + 1) <= left))
      |> Enum.min_by(&levels[&1], fn -> nil end)

    case {next, rest} do
      {nil, [filler | rest]} when left > 0 ->
        levels |> Map.put(filler, 0) |> raise_lowest(candidates ++ [filler], rest, left, sk)

      {nil, _rest} ->
        levels

      {skill, _rest} ->
        price = cost(sk, levels[skill], levels[skill] + 1)
        raise_lowest(Map.update!(levels, skill, &(&1 + 1)), candidates, rest, left - price, sk)
    end
  end

  defp label(skill), do: skill |> String.replace("_", " ") |> String.capitalize()

  defp ordered(table, first) do
    Enum.sort_by(table, fn {id, _} -> {id != first, id} end)
  end

  defp signed(n) when n >= 0, do: "+#{n}"
  defp signed(n), do: "#{n}"

  defp validate_rules!(labels, creation) do
    for {race, choice} <- creation["race_choices"] do
      unless Map.has_key?(labels["races"], race),
        do: raise(ArgumentError, "creation.json: race_choices for unknown race #{inspect(race)}")

      bad = Enum.reject(choice["from"] ++ Map.keys(choice["replaces"]), &(&1 in @stats))

      unless bad == [],
        do: raise(ArgumentError, "creation.json: unknown stats #{inspect(bad)} for #{race}")
    end

    known = Mechanics.skill_stat_map()

    for {race, bonus} <- creation["skills"]["race_bonuses"] do
      unless Map.has_key?(labels["races"], race),
        do: raise(ArgumentError, "creation.json: skill bonus for unknown race #{inspect(race)}")

      bad = bonus |> Map.get("fixed", %{}) |> Map.keys() |> Enum.reject(&Map.has_key?(known, &1))

      unless bad == [],
        do: raise(ArgumentError, "creation.json: unknown skills #{inspect(bad)} for #{race}")
    end

    :ok
  end

  # Resolved at runtime: in a release priv is not at its build path.
  defp creation_path,
    do: Path.join([:code.priv_dir(:ex_tales_forge), "characters", "creation.json"])
end
