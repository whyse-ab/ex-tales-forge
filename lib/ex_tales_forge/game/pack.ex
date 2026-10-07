defmodule TalesForge.Game.Pack do
  @moduledoc """
  File loader for complete adventure packs under `priv/adventures/<id>/`.

  Fail-fast on missing start, dangling exits, portent spawn targets, or bad
  character levers (Maslow, concerns, OCEAN; see `TalesForge.Characters.Levers`).
  Crossroads is **not** loaded through this module at session create, but its
  player character file is (`player_character!/1`).

  The player character lives in `characters/<id>.json`: the sheet that goes
  into `world_state["character"]`, plus the levers `ocean`, `maslow` and
  `concerns`, which `sheet/1` strips.

  A behaviour variant (`TalesForge.Game.Variant`) can replace whole NPCs:
  `variants/<variant>/npcs/<id>.{md,json}` takes the place of `npcs/<id>.*`
  for sessions of that variant (e.g. the pre-rework Brenna for `baseline`).

  A world feature (`TalesForge.Game.Features`) adds a pack extension,
  `extensions/<feature>/` with optional `world/`, `npcs/`, `fronts/` and
  `extension.json`. Its places, people and fronts are added to the base pack
  (an id may not repeat); an exit from a new place to a base place is added
  back on the base place too, so the graph stays two-way; `extension.json`
  `"npc_hooks"` appends hooks to NPCs already loaded.

  A location's blurb is the first paragraph of its body under the heading.
  The baseline variant keeps the old reading, which returned the heading
  itself (`# Valley Inn`), so its prompts stay unchanged.
  """

  alias TalesForge.Characters.{Defaults, Levers}
  alias TalesForge.Game.Fronts
  alias TalesForge.Game.WorldClock

  @sheet_keys ~w(id name race stats skills)

  @doc """
  Loads and validates a pack for `variant`, with the extensions of
  `features`. Raises `ArgumentError` on a broken pack.
  """
  @spec load(String.t(), String.t(), [String.t()]) :: map()
  def load(adventure_id, variant \\ "default", features \\ [])

  def load(adventure_id, variant, features) when is_binary(adventure_id) and adventure_id != "" do
    dir = Path.join(adventures_dir(), adventure_id)

    unless File.dir?(dir) do
      raise ArgumentError, "adventure pack missing: #{adventure_id}"
    end

    adventure = load_adventure!(dir)
    extensions = load_extensions!(dir, features, variant)
    locations = dir |> load_locations!(variant) |> merge_locations!(extensions)
    npcs = dir |> load_npcs!(variant) |> merge_npcs!(extensions)
    defaults = Defaults.rules(adventure_id)
    Enum.each(npcs, &validate_npc!(&1, defaults, "#{adventure_id} NPC #{&1["id"]}"))
    player_character = player_character!(adventure_id)
    fronts_dir = Path.join(dir, "fronts")

    fronts =
      fronts_dir
      |> Fronts.parse_dir!()
      |> Enum.map(&attach_identity(&1, fronts_dir))
      |> Kernel.++(Enum.flat_map(extensions, & &1.fronts))
      |> unique_ids!("front")

    validate_graph!(adventure["starting_location_id"], locations)
    Fronts.validate!(fronts)

    %{
      adventure_id: adventure["adventure_id"] || adventure_id,
      name: adventure["name"] || adventure_id,
      starting_location_id: adventure["starting_location_id"],
      initial_present_npc_ids: List.wrap(adventure["initial_present_npc_ids"]),
      situation_lines: List.wrap(adventure["situation_lines"]),
      locations: locations,
      npcs: npcs,
      player_character: player_character,
      fronts: fronts
    }
  end

  def load(_, _, _), do: raise(ArgumentError, "adventure_id required")

  @doc """
  The starting world_state of a new session of the pack: location, places,
  present NPCs, clock, character and live fronts, plus `"features"` when any.
  """
  @spec materialize(String.t(), String.t(), [String.t()]) :: map()
  def materialize(adventure_id, variant \\ "default", features \\ [])
      when is_binary(adventure_id) do
    features = TalesForge.Game.Features.normalize(features)
    pack = load(adventure_id, variant, features)
    start_id = pack.starting_location_id
    start = Map.fetch!(pack.locations, start_id)
    elara = sheet(pack.player_character)
    tick = WorldClock.default_start_tick()

    live_fronts =
      pack.fronts
      |> Enum.filter(&(&1["status"] == "live"))
      |> Enum.map(& &1["id"])
      |> Enum.sort()

    %{
      "adventure_id" => pack.adventure_id,
      "location_id" => start_id,
      "location_name" => start["name"],
      "present_npcs" => pack.initial_present_npc_ids,
      "world_tick" => tick,
      "world_clock" => WorldClock.format(tick),
      "last_scene_location" => nil,
      "situation_lines" => pack.situation_lines,
      "character" => Map.put(elara, "location_id", start_id),
      "npc_state" => %{},
      "locations" => pack.locations,
      "live_fronts" => live_fronts,
      "public_facts" => []
    }
    |> put_features(features)
  end

  defp put_features(world, []), do: world
  defp put_features(world, features), do: Map.put(world, "features", features)

  @doc """
  The adventure's player character file (`characters/*.json`), levers included.
  Raises `ArgumentError` if there is not exactly one file, or if the sheet or
  the levers are invalid.
  """
  def player_character!(adventure_id) when is_binary(adventure_id) do
    dir = Path.join([adventures_dir(), adventure_id, "characters"])

    case Path.wildcard(Path.join(dir, "*.json")) do
      [path] ->
        path |> File.read!() |> Jason.decode!() |> validate_player_character!(path)

      [] ->
        raise ArgumentError, "no player character in #{dir}"

      paths ->
        raise ArgumentError, "expected one player character in #{dir}, got #{length(paths)}"
    end
  end

  @doc "A character file without its levers: the map stored as `world_state[\"character\"]`."
  def sheet(character) when is_map(character), do: Map.drop(character, Levers.lever_keys())

  @doc false
  def validate_player_character!(character, source) when is_map(character) do
    Enum.each(@sheet_keys, fn key ->
      unless Map.has_key?(character, key) do
        raise ArgumentError, "#{source}: player character needs #{inspect(key)}"
      end
    end)

    Levers.validate!(character, source)
    character
  end

  defp validate_npc!(npc, defaults, source) do
    Levers.validate!(npc, source)

    case npc["derive"] do
      nil -> :ok
      inputs when is_map(inputs) -> Defaults.validate_inputs!(inputs, defaults, source)
      other -> raise ArgumentError, "#{source}: derive must be a map, got #{inspect(other)}"
    end
  end

  @doc false
  def validate_graph!(start, locations) do
    unless is_binary(start) and Map.has_key?(locations, start) do
      raise ArgumentError, "starting_location_id #{inspect(start)} missing from locations"
    end

    locations
    |> Enum.flat_map(fn {id, loc} -> Enum.map(List.wrap(loc["exits"]), &{id, &1}) end)
    |> Enum.each(fn {id, exit_id} ->
      unless Map.has_key?(locations, exit_id) do
        raise ArgumentError, "location #{id} exit #{inspect(exit_id)} missing from locations"
      end
    end)

    :ok
  end

  defp load_adventure!(dir) do
    path = Path.join(dir, "adventure.md")

    unless File.exists?(path) do
      raise ArgumentError, "adventure.md missing in #{dir}"
    end

    {fm, _body} = parse_md!(path)
    stringify_keys(fm)
  end

  defp attach_identity(front, fronts_dir) do
    path = Path.join(fronts_dir, front["id"] <> ".md")

    if File.exists?(path) do
      {_fm, body} = parse_md!(path)
      Map.put(front, "identity", String.trim(body))
    else
      front
    end
  end

  defp load_locations!(dir, variant) do
    world_dir = Path.join(dir, "world")

    unless File.dir?(world_dir) do
      raise ArgumentError, "world/ missing in #{dir}"
    end

    load_location_dir(world_dir, variant)
  end

  defp load_location_dir(world_dir, variant) do
    world_dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.map(&parse_location!(&1, variant))
    |> Map.new(fn loc -> {loc["id"], loc} end)
  end

  # --- extensions (world features) -------------------------------------------

  defp load_extensions!(_dir, _features, "baseline"), do: []

  defp load_extensions!(dir, features, variant) do
    features
    |> TalesForge.Game.Features.normalize()
    |> Enum.map(&{&1, Path.join([dir, "extensions", &1])})
    |> Enum.filter(fn {_feature, ext_dir} -> File.dir?(ext_dir) end)
    |> Enum.map(fn {feature, ext_dir} -> load_extension!(feature, ext_dir, variant) end)
  end

  defp load_extension!(feature, ext_dir, variant) do
    world_dir = Path.join(ext_dir, "world")
    fronts_dir = Path.join(ext_dir, "fronts")
    meta_path = Path.join(ext_dir, "extension.json")

    %{
      feature: feature,
      locations: if(File.dir?(world_dir), do: load_location_dir(world_dir, variant), else: %{}),
      npcs: load_npc_dir!(Path.join(ext_dir, "npcs")),
      fronts:
        if(File.dir?(fronts_dir),
          do: fronts_dir |> Fronts.parse_dir!() |> Enum.map(&attach_identity(&1, fronts_dir)),
          else: []
        ),
      meta:
        if(File.exists?(meta_path), do: meta_path |> File.read!() |> Jason.decode!(), else: %{})
    }
  end

  defp merge_locations!(base, extensions) do
    Enum.reduce(extensions, base, fn ext, acc ->
      Enum.reduce(ext.locations, acc, &add_location!(&2, &1, ext.feature))
    end)
  end

  defp add_location!(places, {id, _loc}, feature) when is_map_key(places, id) do
    raise ArgumentError, "extension #{feature}: location #{id} already exists"
  end

  defp add_location!(places, {id, loc}, _feature) do
    places
    |> Map.put(id, loc)
    |> add_return_exits(id, loc["exits"])
  end

  # An exit from a new place back to a known place gets its way back.
  defp add_return_exits(places, id, exits) do
    Enum.reduce(List.wrap(exits), places, &add_return_exit(&2, &1, id))
  end

  defp add_return_exit(places, exit_id, id) do
    case Map.get(places, exit_id) do
      %{"exits" => back} = other when is_list(back) ->
        if id in back,
          do: places,
          else: Map.put(places, exit_id, %{other | "exits" => back ++ [id]})

      _ ->
        places
    end
  end

  defp merge_npcs!(base, extensions) do
    extensions
    |> Enum.reduce(base, fn ext, acc ->
      (acc ++ ext.npcs)
      |> unique_ids!("NPC")
      |> append_hooks(Map.get(ext.meta, "npc_hooks", %{}))
    end)
  end

  defp append_hooks(npcs, hooks) when map_size(hooks) == 0, do: npcs

  defp append_hooks(npcs, hooks) do
    Enum.map(npcs, fn npc ->
      case Map.get(hooks, npc["id"]) do
        extra when is_list(extra) -> Map.put(npc, "hooks", List.wrap(npc["hooks"]) ++ extra)
        _ -> npc
      end
    end)
  end

  defp unique_ids!(items, what) do
    items
    |> Enum.frequencies_by(& &1["id"])
    |> Enum.each(fn {id, n} ->
      if n > 1, do: raise(ArgumentError, "#{what} #{inspect(id)} defined more than once")
    end)

    items
  end

  defp parse_location!(path, variant) do
    {raw_fm, body} = parse_md!(path)
    attrs = stringify_keys(raw_fm)
    id = attrs["id"] || Path.rootname(Path.basename(path))

    %{
      "id" => id,
      "name" => attrs["name"] || id,
      "exits" => List.wrap(attrs["exits"]),
      "blurb" => attrs["blurb"] || location_blurb(body, variant),
      "fixtures" => List.wrap(attrs["fixtures"]),
      "ground_items" => List.wrap(attrs["ground_items"])
    }
  end

  defp load_npcs!(dir, variant) do
    base = load_npc_dir!(Path.join(dir, "npcs"))
    overrides = load_npc_dir!(Path.join([dir, "variants", variant, "npcs"]))
    override_ids = MapSet.new(overrides, & &1["id"])

    Enum.reject(base, &MapSet.member?(override_ids, &1["id"])) ++ overrides
  end

  defp load_npc_dir!(npc_dir) do
    if File.dir?(npc_dir) do
      markdown =
        npc_dir
        |> Path.join("*.md")
        |> Path.wildcard()
        |> Enum.map(&parse_npc!/1)

      json_by_id =
        npc_dir
        |> Path.join("*.json")
        |> Path.wildcard()
        |> Enum.map(&parse_npc_json!/1)
        |> Map.new(&{&1["id"], &1})

      merge_npc_json(markdown, json_by_id)
    else
      []
    end
  end

  defp parse_npc!(path) do
    {raw_fm, body} = parse_md!(path)
    attrs = stringify_keys(raw_fm)
    id = attrs["id"] || Path.rootname(Path.basename(path))

    %{
      "id" => id,
      "name" => attrs["name"] || id,
      "race" => attrs["race"] || "human",
      "role" => attrs["role"],
      "default_location_id" => attrs["default_location_id"],
      "appearance" => attrs["appearance"] || extract_section(body, "Appearance"),
      "personality" => attrs["personality"] || extract_section(body, "Personality"),
      "backstory" => attrs["backstory"] || extract_section(body, "Backstory"),
      "motivations" => npc_motivations(attrs["motivations"], body)
    }
  end

  defp parse_npc_json!(path) do
    attrs = path |> File.read!() |> Jason.decode!() |> stringify_keys()

    Map.update(attrs, "motivations", %{}, &normalize_motivations/1)
  end

  defp merge_npc_json(markdown, json_by_id) do
    merged =
      Enum.map(markdown, fn npc ->
        case Map.get(json_by_id, npc["id"]) do
          nil -> npc
          extra -> deep_merge_npc(npc, extra)
        end
      end)

    md_ids = MapSet.new(merged, & &1["id"])

    json_only =
      json_by_id
      |> Map.values()
      |> Enum.reject(&MapSet.member?(md_ids, &1["id"]))

    merged ++ json_only
  end

  defp deep_merge_npc(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, l, r ->
      if is_map(l) and is_map(r), do: deep_merge_npc(l, r), else: r
    end)
  end

  defp npc_motivations(from_frontmatter, body) do
    from_body = body |> extract_section("Motivations") |> normalize_motivations()
    Map.merge(from_body, normalize_motivations(from_frontmatter))
  end

  defp normalize_motivations(nil), do: %{}
  defp normalize_motivations(""), do: %{}

  defp normalize_motivations(map) when is_map(map) do
    map
    |> stringify_keys()
    |> Map.update("current_concern", nil, &normalize_concern/1)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp normalize_motivations(text) when is_binary(text) do
    %{}
    |> maybe_put_motivation("primary_need", capture_need(text))
    |> maybe_put_motivation("current_concern", normalize_concern(capture_concern(text)))
  end

  defp normalize_motivations(_), do: %{}

  defp normalize_concern(%{} = concern), do: stringify_keys(concern)

  defp normalize_concern(focus) when is_binary(focus) and focus != "" do
    %{
      "focus" => focus |> String.trim() |> String.trim_trailing("."),
      "priority" => 8,
      "blocked_by" => nil
    }
  end

  defp normalize_concern(_), do: nil

  defp capture_need(text) do
    case Regex.run(~r/Primary need:\s*(.+?)(?:\.?\s*Current concern:|$)/is, text) do
      [_, need] -> need |> String.trim() |> String.trim_trailing(".")
      _ -> nil
    end
  end

  defp capture_concern(text) do
    case Regex.run(~r/Current concern:\s*(.+)/is, text) do
      [_, focus] -> String.trim(focus)
      _ -> nil
    end
  end

  defp maybe_put_motivation(map, _key, nil), do: map
  defp maybe_put_motivation(map, key, value), do: Map.put(map, key, value)

  defp parse_md!(path) do
    content = File.read!(path)

    case Regex.run(~r/\A\s*---\s*\n(.*?)\n---\s*\n(.*)/s, content, capture: :all_but_first) do
      [yaml, body] -> {parse_yaml(yaml), String.trim(body)}
      _ -> {%{}, String.trim(content)}
    end
  end

  defp parse_yaml(yaml) do
    yaml
    |> String.split(~r/\r?\n/)
    |> Enum.reduce({%{}, nil}, fn line, {acc, list_key} ->
      trimmed = String.trim(line)
      parse_yaml_line(trimmed, acc, list_key)
    end)
    |> elem(0)
  end

  defp parse_yaml_line("", acc, list_key), do: {acc, list_key}

  defp parse_yaml_line("#" <> _, acc, list_key), do: {acc, list_key}

  defp parse_yaml_line("- " <> rest, acc, list_key) when is_binary(list_key) do
    {Map.update!(acc, list_key, &(&1 ++ [scalar(rest)])), list_key}
  end

  defp parse_yaml_line(trimmed, acc, list_key) do
    cond do
      match = Regex.run(~r/^([A-Za-z0-9_]+):\s*$/, trimmed) ->
        key = Enum.at(match, 1)
        {Map.put(acc, key, []), key}

      match = Regex.run(~r/^([A-Za-z0-9_]+):\s*(.+)$/, trimmed) ->
        key = Enum.at(match, 1)
        {Map.put(acc, key, scalar(String.trim(Enum.at(match, 2)))), nil}

      true ->
        {acc, list_key}
    end
  end

  defp scalar(val) do
    cond do
      String.match?(val, ~r/^\[.*\]$/) ->
        val
        |> String.trim_leading("[")
        |> String.trim_trailing("]")
        |> String.split(~r/\s*,\s*/)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&String.trim(&1, "\"'"))

      String.match?(val, ~r/^true$/i) ->
        true

      String.match?(val, ~r/^false$/i) ->
        false

      String.match?(val, ~r/^-?\d+$/) ->
        String.to_integer(val)

      true ->
        String.trim(val, "\"'")
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {to_string(k), stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp location_blurb(body, "baseline"), do: first_paragraph(body)

  defp location_blurb(body, _variant) do
    body
    |> String.replace(~r/\A\s*#[^\n]*\n+/, "")
    |> first_paragraph()
  end

  defp first_paragraph(body) do
    body
    |> String.split(~r/\n\s*\n/, parts: 2)
    |> List.first()
    |> to_string()
    |> String.replace(~r/^#+\s+.*\n+/, "")
    |> String.trim()
  end

  defp extract_section(body, heading) do
    pattern = ~r/^##\s+#{Regex.escape(heading)}\s*\n+([^#]*)/m

    case Regex.run(pattern, body, capture: :all_but_first) do
      [text] -> String.trim(text)
      _ -> nil
    end
  end

  # Resolved at runtime (not a module attribute): in a release priv is not at its build path.
  defp adventures_dir, do: Path.join(:code.priv_dir(:ex_tales_forge), "adventures")
end
