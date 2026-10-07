defmodule TalesForge.Characters.Defaults do
  @moduledoc """
  Character defaults derived in pure Elixir from race, class, social standing,
  occupation and seniority (Character plan, section 7). People are assumed to
  be reasonably skilled at their job and to have a typical personality for it.

  * **Rules** come from the global base `priv/characters/defaults.json`,
    extended per world by `priv/adventures/<id>/character_defaults.json`. A pack
    may add labels, never redefine or remove a base one (`rules/1`).
  * **`derive/3`** turns inputs into stats, skills, OCEAN, a Maslow level,
    concerns and coins. Skills are deterministic (so trainer gaps are
    predictable); stats and OCEAN get a small variation of −1, 0 or +1 from a
    per-character seed (`seed/2`), so two innkeepers differ but a character is
    stable on reload.
  * **`merge/2`** lays authored overrides over the defaults: maps per key
    (stats, skills, OCEAN), scalars and lists replace, a skill set to 0 is
    removed.
  * **`apply/3`** does both for an authored definition with a `derive` block.

  No database, no AI.
  """

  alias TalesForge.Characters.Levers
  alias TalesForge.Game.Mechanics

  @stats ~w(STR DEX CON INT WIS CHA)
  @input_defaults %{
    "race" => "human",
    "class" => "none",
    "standing" => "commoner",
    "occupation" => "laborer",
    "seniority" => "journeyman"
  }
  @tables ~w(seniority races classes standings occupations)
  @max_concerns 3

  @type rules :: %{required(String.t()) => map() | list()}
  @type inputs :: %{optional(String.t()) => String.t()}

  @doc "Input labels used when a `derive` block leaves one out."
  @spec input_defaults() :: inputs()
  def input_defaults, do: @input_defaults

  @doc """
  The rules for an adventure: the global base extended by the pack's
  `character_defaults.json`, if any. Raises `ArgumentError` if a pack redefines
  a base label or a table refers to an unknown skill, stat, trait, Maslow level
  or concern focus.
  """
  @spec rules(String.t() | nil) :: rules()
  def rules(adventure_id \\ nil) do
    base = read!(base_path())

    case adventure_id && pack_path(adventure_id) do
      path when is_binary(path) ->
        if File.exists?(path),
          do: extend_rules!(base, read!(path), path),
          else: validate_rules!(base)

      _ ->
        validate_rules!(base)
    end
  end

  @doc false
  # Base rules extended by one pack's additions, then validated. Public for tests.
  @spec extend_rules!(rules(), map(), String.t()) :: rules()
  def extend_rules!(base, pack, source), do: base |> extend!(pack, source) |> validate_rules!()

  @doc "A stable integer seed for one character: a hash of the session id and the character key."
  @spec seed(String.t() | nil, String.t()) :: non_neg_integer()
  def seed(session_id, character_key), do: :erlang.phash2({to_string(session_id), character_key})

  @doc """
  Derives defaults from `inputs` (`race`, `class`, `standing`, `occupation`,
  `seniority`; missing ones take `input_defaults/0`). Returns a map with string
  keys: `stats`, `skills`, `ocean`, `maslow`, `concerns`, `coins`. Raises
  `ArgumentError` for an unknown label.
  """
  @spec derive(inputs(), rules(), integer()) :: map()
  def derive(inputs, rules, seed) when is_map(inputs) and is_integer(seed) do
    inputs = resolve_inputs!(inputs, rules)
    race = rules["races"][inputs["race"]]
    class = rules["classes"][inputs["class"]]
    standing = rules["standings"][inputs["standing"]]
    occupation = rules["occupations"][inputs["occupation"]]
    tier = rules["seniority"][inputs["seniority"]]

    %{
      "stats" => stats(race, class, seed),
      "skills" => skills(occupation, class, tier),
      "ocean" => ocean(race, occupation, seed),
      "maslow" => maslow(occupation["maslow"], standing["maslow_floor"]),
      "concerns" => concerns(occupation, standing),
      "coins" => standing["coins"]
    }
  end

  @doc """
  Lays authored `overrides` over derived `defaults`. `stats`, `skills` and
  `ocean` merge per key; every other key replaces. A skill set to 0 is removed.
  """
  @spec merge(map(), map()) :: map()
  def merge(defaults, overrides) when is_map(defaults) and is_map(overrides) do
    merged =
      Map.merge(defaults, overrides, fn
        key, d, o when key in ~w(stats skills ocean) and is_map(d) and is_map(o) ->
          Map.merge(d, o)

        _key, _d, o ->
          o
      end)

    case merged do
      %{"skills" => skills} when is_map(skills) ->
        Map.put(merged, "skills", Map.reject(skills, fn {_k, v} -> v == 0 end))

      _ ->
        merged
    end
  end

  @doc """
  Applies the defaults to an authored definition that has a `derive` block.

  The authored keys are the overrides. OCEAN authored as
  `motivations.personality_traits` counts as an `ocean` override (the GM prompt
  keeps reading the authored traits). The result keeps the `derive` block and
  adds the derived `stats`, `skills`, `ocean`, `maslow`, `concerns` and `coins`
  where the author didn't set them. A definition without `derive` is returned
  unchanged.
  """
  @spec apply(map(), rules(), integer()) :: map()
  def apply(%{"derive" => inputs} = definition, rules, seed) when is_map(inputs) do
    inputs = maybe_put_race(inputs, definition["race"])

    overrides =
      case get_in(definition, ["motivations", "personality_traits"]) do
        traits when is_map(traits) -> Map.put_new(definition, "ocean", traits)
        _ -> definition
      end

    inputs |> derive(rules, seed) |> merge(overrides)
  end

  def apply(definition, _rules, _seed) when is_map(definition), do: definition

  defp maybe_put_race(inputs, race) when is_binary(race), do: Map.put_new(inputs, "race", race)
  defp maybe_put_race(inputs, _race), do: inputs

  @doc "Checks a `derive` block against the rules; raises `ArgumentError` naming `source`."
  @spec validate_inputs!(map(), rules(), String.t()) :: :ok
  def validate_inputs!(inputs, rules, source) when is_map(inputs) do
    resolve_inputs!(inputs, rules)
    :ok
  rescue
    e in ArgumentError ->
      reraise ArgumentError, "#{source}: #{Exception.message(e)}", __STACKTRACE__
  end

  # --- derivation ---------------------------------------------------------------

  defp stats(race, class, seed) do
    Map.new(@stats, fn stat ->
      value =
        10 + Map.get(race["stats"], stat, 0) + Map.get(class["stats"], stat, 0) +
          variation(seed, stat)

      {stat, clamp(value, 3, 18)}
    end)
  end

  defp skills(occupation, class, tier) do
    secondary = Map.new(occupation["secondary"], &{&1, div(tier, 2)})
    core = Map.new(occupation["core"], &{&1, tier})

    class["skills"]
    |> Map.new(&{&1, 3})
    |> Map.merge(secondary, fn _k, a, b -> max(a, b) end)
    |> Map.merge(core, fn _k, a, b -> max(a, b) end)
  end

  defp ocean(race, occupation, seed) do
    Map.new(Levers.ocean_traits(), fn trait ->
      value =
        5 + Map.get(race["ocean"], trait, 0) + Map.get(occupation["ocean"], trait, 0) +
          variation(seed, trait)

      {trait, clamp(value, 1, 10)}
    end)
  end

  # The lower need wins: a noble who is hungry is still hungry.
  defp maslow(level, nil), do: level

  defp maslow(level, floor) do
    levels = Levers.maslow_levels()
    if index(levels, floor) < index(levels, level), do: floor, else: level
  end

  defp concerns(occupation, standing) do
    (occupation["concerns"] ++ List.wrap(standing["concern"]))
    |> Enum.sort_by(&(-Map.get(&1, "priority", 5)))
    |> Enum.take(@max_concerns)
  end

  defp variation(seed, key), do: :erlang.phash2({seed, key}, 3) - 1

  defp clamp(value, lo, hi), do: value |> max(lo) |> min(hi)

  defp index(list, item), do: Enum.find_index(list, &(&1 == item))

  # --- rules ----------------------------------------------------------------------

  defp resolve_inputs!(inputs, rules) do
    resolved = Map.merge(@input_defaults, Map.reject(inputs, fn {_k, v} -> is_nil(v) end))

    for {input, table} <- [
          {"race", "races"},
          {"class", "classes"},
          {"standing", "standings"},
          {"occupation", "occupations"},
          {"seniority", "seniority"}
        ] do
      unless Map.has_key?(rules[table], resolved[input]) do
        raise ArgumentError, "unknown #{input} #{inspect(resolved[input])}"
      end
    end

    resolved
  end

  defp extend!(base, pack, source) do
    Enum.reduce(pack, base, fn
      {"_doc", _}, acc ->
        acc

      {"concern_focuses", extra}, acc ->
        Map.update!(acc, "concern_focuses", &Enum.uniq(&1 ++ extra))

      {table, extra}, acc when table in @tables and is_map(extra) ->
        clash = extra |> Map.keys() |> Enum.filter(&Map.has_key?(acc[table], &1))

        unless clash == [] do
          raise ArgumentError, "#{source}: cannot redefine base #{table} #{inspect(clash)}"
        end

        Map.update!(acc, table, &Map.merge(&1, extra))

      {key, _}, _acc ->
        raise ArgumentError, "#{source}: unknown key #{inspect(key)}"
    end)
  end

  defp validate_rules!(rules) do
    skills = Mechanics.skill_stat_map() |> Map.keys() |> MapSet.new()
    focuses = MapSet.new(rules["concern_focuses"])

    for {id, occ} <- rules["occupations"] do
      check_skills!(occ["core"] ++ occ["secondary"], skills, "occupation #{id}")
      check_traits!(occ["ocean"], "occupation #{id}")
      check_maslow!(occ["maslow"], "occupation #{id}")
      Enum.each(occ["concerns"], &check_focus!(&1, focuses, "occupation #{id}"))
    end

    for {id, class} <- rules["classes"] do
      check_skills!(class["skills"], skills, "class #{id}")
      check_stats!(class["stats"], "class #{id}")
    end

    for {id, race} <- rules["races"] do
      check_stats!(race["stats"], "race #{id}")
      check_traits!(race["ocean"], "race #{id}")
    end

    for {id, standing} <- rules["standings"] do
      if floor = standing["maslow_floor"], do: check_maslow!(floor, "standing #{id}")
      if c = standing["concern"], do: check_focus!(c, focuses, "standing #{id}")
    end

    rules
  end

  defp check_skills!(list, known, where) do
    case Enum.reject(list, &MapSet.member?(known, &1)) do
      [] -> :ok
      bad -> raise ArgumentError, "character defaults #{where}: unknown skills #{inspect(bad)}"
    end
  end

  defp check_stats!(map, where) do
    case Map.keys(map) -- @stats do
      [] -> :ok
      bad -> raise ArgumentError, "character defaults #{where}: unknown stats #{inspect(bad)}"
    end
  end

  defp check_traits!(map, where) do
    case Map.keys(map) -- Levers.ocean_traits() do
      [] ->
        :ok

      bad ->
        raise ArgumentError, "character defaults #{where}: unknown OCEAN traits #{inspect(bad)}"
    end
  end

  defp check_maslow!(level, where) do
    unless level in Levers.maslow_levels() do
      raise ArgumentError, "character defaults #{where}: unknown Maslow level #{inspect(level)}"
    end
  end

  defp check_focus!(%{"focus" => focus, "text" => text}, focuses, where) when is_binary(text) do
    unless MapSet.member?(focuses, focus) do
      raise ArgumentError, "character defaults #{where}: unknown concern focus #{inspect(focus)}"
    end
  end

  defp check_focus!(concern, _focuses, where),
    do: raise(ArgumentError, "character defaults #{where}: bad concern #{inspect(concern)}")

  defp read!(path), do: path |> File.read!() |> Jason.decode!()

  # Resolved at runtime: in a release priv is not at its build path.
  defp base_path, do: Path.join([:code.priv_dir(:ex_tales_forge), "characters", "defaults.json"])

  defp pack_path(adventure_id),
    do:
      Path.join([
        :code.priv_dir(:ex_tales_forge),
        "adventures",
        adventure_id,
        "character_defaults.json"
      ])
end
