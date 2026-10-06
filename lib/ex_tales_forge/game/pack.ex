defmodule TalesForge.Game.Pack do
  @moduledoc """
  File loader for complete adventure packs under `priv/adventures/<id>/`.

  Fail-fast on missing start, dangling exits, or portent spawn targets.
  Crossroads is **not** loaded through this module at session create.
  """

  alias TalesForge.Game.Fronts
  alias TalesForge.Game.World
  alias TalesForge.Game.WorldClock

  def load(adventure_id) when is_binary(adventure_id) and adventure_id != "" do
    dir = Path.join(adventures_dir(), adventure_id)

    unless File.dir?(dir) do
      raise ArgumentError, "adventure pack missing: #{adventure_id}"
    end

    adventure = load_adventure!(dir)
    locations = load_locations!(dir)
    npcs = load_npcs!(dir)
    fronts_dir = Path.join(dir, "fronts")
    fronts = fronts_dir |> Fronts.parse_dir!() |> Enum.map(&attach_identity(&1, fronts_dir))

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
      fronts: fronts
    }
  end

  def load(_), do: raise(ArgumentError, "adventure_id required")

  def materialize(adventure_id) when is_binary(adventure_id) do
    pack = load(adventure_id)
    start_id = pack.starting_location_id
    start = Map.fetch!(pack.locations, start_id)
    elara = World.default_world_state()["character"]
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

  defp load_locations!(dir) do
    world_dir = Path.join(dir, "world")

    unless File.dir?(world_dir) do
      raise ArgumentError, "world/ missing in #{dir}"
    end

    world_dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.map(&parse_location!/1)
    |> Map.new(fn loc -> {loc["id"], loc} end)
  end

  defp parse_location!(path) do
    {raw_fm, body} = parse_md!(path)
    attrs = stringify_keys(raw_fm)
    id = attrs["id"] || Path.rootname(Path.basename(path))

    %{
      "id" => id,
      "name" => attrs["name"] || id,
      "exits" => List.wrap(attrs["exits"]),
      "blurb" => attrs["blurb"] || first_paragraph(body),
      "fixtures" => List.wrap(attrs["fixtures"]),
      "ground_items" => List.wrap(attrs["ground_items"])
    }
  end

  defp load_npcs!(dir) do
    npc_dir = Path.join(dir, "npcs")

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
