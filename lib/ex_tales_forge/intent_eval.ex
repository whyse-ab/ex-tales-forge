defmodule TalesForge.IntentEval do
  @moduledoc """
  Offline evaluation harness for player-intent reading.

  Loads the labelled fixture (`test/fixtures/intent_eval/items.jsonl` and
  `worlds.json`), turns each item into the same intent context the live game
  builds (`TalesForge.Game.Context`), runs one or more readers over it
  (`TalesForge.IntentEval.Readers`) and scores them against the gold labels
  (`TalesForge.IntentEval.Metrics`). `TalesForge.IntentEval.Report` renders the
  result as Markdown; `mix intent.eval` is the entry point.

  Nothing here is wired into live turns. The fixture labels are **drafts**
  (`reviewed: false`); see the fixture README before trusting a number.
  """

  alias TalesForge.Game.Mechanics
  alias TalesForge.IntentEval.{Metrics, Readers, Report}

  @default_fixture "test/fixtures/intent_eval/items.jsonl"
  @default_worlds "test/fixtures/intent_eval/worlds.json"

  @typedoc "One fixture item, string-keyed as stored in the JSONL."
  @type item :: map()

  @typedoc "An item paired with each reader's reading of it."
  @type scored :: %{item: item(), readings: %{atom() => map()}}

  @doc """
  Runs the evaluation and returns `{report_markdown, results}`.

  Options:

    * `:fixture` / `:worlds` — paths (default the repo fixture);
    * `:split` — `"tune"`, `"holdout"` or `"all"` (default `"tune"`);
    * `:readers` — list of `:jev | :heuristic | :tier1` (default `[:jev, :heuristic, :tier1]`);
    * `:ask_below` — clarification threshold for the clarifying-rate metric;
    * `:limit` — cap the number of items (after the split filter);
    * `:jev` — options forwarded to the Jev reader (`:api_key`, `:model`, `:timeout_ms`).
  """
  @spec run(keyword()) :: {String.t(), map()}
  def run(opts \\ []) do
    split = Keyword.get(opts, :split, "tune")
    readers = Keyword.get(opts, :readers, [:jev, :heuristic, :tier1])

    items =
      opts
      |> Keyword.get(:fixture, default_path(@default_fixture))
      |> load_items()
      |> filter_split(split)
      |> maybe_limit(Keyword.get(opts, :limit))

    worlds = load_worlds(Keyword.get(opts, :worlds, default_path(@default_worlds)))

    scored = score(items, worlds, readers, opts)

    metrics =
      Map.new(readers, fn reader ->
        {reader, Metrics.evaluate(reader, scored, opts)}
      end)

    report = Report.render(split, readers, items, metrics, opts)
    {report, %{items: items, scored: scored, metrics: metrics}}
  end

  @doc "Reads the JSONL fixture into a list of string-keyed item maps."
  @spec load_items(String.t()) :: [item()]
  def load_items(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(&Jason.decode!/1)
    |> Enum.to_list()
  end

  @doc "Reads the worlds file: a map of world id to its places map."
  @spec load_worlds(String.t()) :: map()
  def load_worlds(path), do: path |> File.read!() |> Jason.decode!()

  @doc "Validates the fixture: ids unique, splits/safety known, gold shapes sane. `:ok` or `{:error, messages}`."
  @spec validate([item()]) :: :ok | {:error, [String.t()]}
  def validate(items) do
    errors =
      duplicate_id_errors(items) ++
        Enum.flat_map(items, &item_errors/1)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp duplicate_id_errors(items) do
    items
    |> Enum.frequencies_by(& &1["id"])
    |> Enum.filter(fn {_id, n} -> n > 1 end)
    |> Enum.map(fn {id, n} -> "duplicate id #{id} (#{n}x)" end)
  end

  defp item_errors(item) do
    id = item["id"] || "(no id)"

    []
    |> check(item["split"] in ["tune", "holdout"], "#{id}: bad split #{inspect(item["split"])}")
    |> check(
      get_in(item, ["gold", "safety"]) in ~w(benign jailbreak prompt_injection nefarious),
      "#{id}: bad safety #{inspect(get_in(item, ["gold", "safety"]))}"
    )
    |> check(is_binary(item["text"]) and item["text"] != "", "#{id}: empty text")
    |> check(valid_action?(get_in(item, ["gold", "action"])), "#{id}: bad gold action")
    |> check(valid_skills?(item), "#{id}: unknown skill in gold")
  end

  defp valid_action?(action) do
    action in Enum.map(action_types(), &Atom.to_string/1)
  end

  defp valid_skills?(item) do
    skills =
      [get_in(item, ["gold", "skill"]) | List.wrap(get_in(item, ["gold", "acceptable_skills"]))]
      |> Enum.reject(&is_nil/1)

    valid = Mechanics.skill_stat_map() |> Map.keys()
    Enum.all?(skills, &(&1 in valid))
  end

  defp check(errors, true, _message), do: errors
  defp check(errors, false, message), do: errors ++ [message]

  @doc """
  Builds the live-game intent context (`TalesForge.Game.Context` shape) for a
  fixture item, resolving its world from `worlds`.
  """
  @spec build_context(item(), map()) :: map()
  def build_context(item, worlds) do
    ctx = item["context"] || %{}
    world_id = ctx["world"]
    places = Map.get(worlds, world_id, %{})
    location_id = ctx["location_id"]
    location = Map.get(places, location_id, %{})
    present = present_ids(ctx)

    %{
      "session_id" => nil,
      "location_id" => location_id,
      "location_name" => Map.get(location, "name", location_id),
      "location_blurb" => Map.get(location, "blurb", ctx["last_narration"] || ""),
      "fixtures" => Map.get(location, "fixtures", []),
      "ground_items" => Map.get(location, "ground_items", []),
      "npc_stock" => ctx["stock"] || %{},
      "exits" => Map.get(location, "exits", []),
      "exit_names" => exit_names(places, Map.get(location, "exits", [])),
      "present_npcs" => present,
      "npc_details" => npc_details(ctx),
      "character" => character(ctx),
      "player_inventory" => ctx["inventory"] || [],
      "situation_lines" => [],
      "recent_turns" => recent_turns(ctx),
      "valid_skills" => Mechanics.skill_stat_map() |> Map.keys() |> Enum.sort(),
      "variant" => "default",
      "places" => places,
      "npc_locations" => npc_locations(ctx),
      "last_narration" => ctx["last_narration"]
    }
  end

  defp present_ids(ctx) do
    ctx |> Map.get("present_npcs", []) |> Enum.map(&Map.get(&1, "id"))
  end

  defp npc_details(ctx) do
    ctx
    |> Map.get("present_npcs", [])
    |> Map.new(fn npc ->
      {npc["id"], %{"name" => npc["name"], "role" => npc["role"]}}
    end)
  end

  defp npc_locations(ctx) do
    ctx
    |> Map.get("elsewhere_npcs", [])
    |> Map.new(fn npc ->
      {npc["id"], %{"name" => npc["name"], "location_id" => npc["location_id"]}}
    end)
  end

  defp character(ctx) do
    %{
      "name" => ctx["character_name"] || "the traveller",
      "coins" => ctx["coins"] || %{},
      "inventory" => ctx["inventory"] || []
    }
  end

  defp recent_turns(ctx) do
    ctx
    |> Map.get("recent_turns", [])
    |> List.wrap()
    |> Enum.map(fn
      %{"action" => _, "outcome" => _} = turn -> turn
      other -> %{"action" => to_string(other), "outcome" => "none"}
    end)
  end

  defp exit_names(places, exits) do
    Map.new(exits, fn id -> {id, get_in(places, [id, "name"]) || id} end)
  end

  @doc "The 16 action types, as atoms."
  @spec action_types() :: [atom()]
  def action_types do
    ~w(observe interact speak move combat use_item pickup drop buy sell trade spend wait train freeform other)a
  end

  defp score(items, worlds, readers, opts) do
    Enum.map(items, fn item ->
      context = build_context(item, worlds)

      readings =
        Map.new(readers, fn reader ->
          {reader, Readers.read(reader, item, context, opts)}
        end)

      %{item: item, readings: readings}
    end)
  end

  defp filter_split(items, "all"), do: items
  defp filter_split(items, split), do: Enum.filter(items, &(&1["split"] == split))

  defp maybe_limit(items, nil), do: items
  defp maybe_limit(items, n) when is_integer(n), do: Enum.take(items, n)

  defp default_path(relative), do: Path.join(File.cwd!(), relative)
end
