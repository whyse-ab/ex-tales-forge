defmodule TalesForge.Game.Fronts.Moves do
  @moduledoc """
  Server-enforced legal move palette. Pure — no Repo.
  """

  require Logger

  @doc """
  Applies the legal move `move` of a front to its runtime state. Moves with
  code of their own (`raise_alert`, `hire_extra`, `mark_debt`) come first; any
  other move must be written out in the pack (`apply_generic/3`).

  `opts`:

    * `:player_at` — the player character's place this tick, used for
      `"@player"` in a pack move (see `apply_generic/3`).

  Returns `{:ok, state}`, or `{:error, reason}` for a move the front cannot
  make now (`:illegal_move`, `:unknown_move`). Raises `ArgumentError` for a
  move the pack does not define.
  """
  @spec apply(map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply(runtime_state, move, pack_def, opts \\ [])

  def apply(runtime_state, "raise_alert", pack_def, _opts) when is_map(runtime_state) do
    fact = get_in(pack_def, ["moves", "raise_alert", "public_fact"]) || %{}
    tick = runtime_state["since_tick"]

    memory = %{
      "who" => "player",
      "tick" => tick,
      "what" => "approached from the west road; scouts unseen",
      "felt" => "threatened"
    }

    state =
      runtime_state
      |> put_in(["clocks", "alert", "value"], "prepared")
      |> update_in(["memories"], &append_memory(&1, memory))
      |> update_in(["public_facts"], &append_unique_fact(&1, stringify_fact(fact)))

    {:ok, state}
  end

  def apply(runtime_state, "hire_extra", pack_def, _opts) when is_map(runtime_state) do
    coin = get_in(runtime_state, ["resources", "coin"]) || 0
    move = get_in(pack_def, ["moves", "hire_extra"]) || %{}
    wage = move["wage"] || 1

    if coin < wage do
      Logger.info("front=#{pack_def["id"]} move=hire_extra reason=no_coin")
      {:error, :illegal_move}
    else
      state =
        runtime_state
        |> put_in(["resources", "coin"], coin - wage)
        |> maybe_put_fact(move["public_fact"])
        |> maybe_put_memory(move["memory"])

      {:ok, state}
    end
  end

  def apply(runtime_state, "mark_debt", pack_def, _opts) when is_map(runtime_state) do
    memory = get_in(pack_def, ["moves", "mark_debt", "memory"]) || %{"felt" => "owed"}
    {:ok, maybe_put_memory(runtime_state, memory)}
  end

  def apply(_runtime_state, "unknown_front_probe", _pack_def, _opts) do
    {:error, :unknown_move}
  end

  def apply(runtime_state, move, pack_def, opts) when is_binary(move) and is_map(runtime_state) do
    case get_in(pack_def, ["moves", move]) do
      %{} = spec -> {:ok, apply_generic(runtime_state, spec, opts)}
      _ -> raise ArgumentError, "unknown legal move #{inspect(move)}"
    end
  end

  @doc """
  A move written out in the pack (`"moves" => %{name => spec}`), for moves
  without code of their own. Every key is optional:

  - `"retract_facts"`: ids of facts that are no longer true;
  - `"public_fact"`: a fact people can perceive where `visibility` says;
  - `"public_facts"`: a list of such facts, for a move that has several;
  - `"memory"`: the actor remembers something;
  - `"status"`: the front's new status (`"spent"` stops it);
  - `"move_people"`: `%{npc_id => location_id}`, applied by `WorldSim`;
  - `"people_memories"`: `%{npc_id => memory}`, applied by `WorldSim`;
  - `"clock"`: `%{name => value}` sets clocks.

  `"@player"` as a place in `move_people` or in a fact's `visibility` means
  where the player character is this tick (`opts[:player_at]`), so a front can
  come to the player. When the player is at one of the places in
  `"player_out_of_reach"` (or the place is unknown), `"player_fallback"` is
  used instead; without a fallback the entry is dropped.

      iex> spec = %{
      ...>   "move_people" => %{"cobb" => "@player"},
      ...>   "player_out_of_reach" => ["orc_nest"],
      ...>   "player_fallback" => "valley_inn"
      ...> }
      iex> TalesForge.Game.Fronts.Moves.apply_generic(%{}, spec, player_at: "smithy")["pending"]
      %{"move_people" => %{"cobb" => "smithy"}}
      iex> TalesForge.Game.Fronts.Moves.apply_generic(%{}, spec, player_at: "orc_nest")["pending"]
      %{"move_people" => %{"cobb" => "valley_inn"}}
  """
  @spec apply_generic(map(), map(), keyword()) :: map()
  def apply_generic(runtime_state, spec, opts \\ []) when is_map(spec) do
    spec = resolve_player(spec, opts[:player_at])

    runtime_state
    |> retract_facts(spec["retract_facts"])
    |> maybe_put_fact(spec["public_fact"])
    |> maybe_put_facts(spec["public_facts"])
    |> maybe_put_memory(spec["memory"])
    |> maybe_put_status(spec["status"])
    |> maybe_queue("move_people", spec["move_people"])
    |> maybe_queue("people_memories", spec["people_memories"])
    |> maybe_set_clocks(spec["clock"])
  end

  @player "@player"

  # "@player" in a move becomes the player's place (or the fallback).
  defp resolve_player(spec, player_at) do
    place = player_place(spec, player_at)

    spec
    |> Map.update("move_people", nil, &resolve_people(&1, place))
    |> Map.update("public_fact", nil, &resolve_visibility(&1, place))
    |> Map.update("public_facts", nil, &resolve_fact_list(&1, place))
  end

  defp player_place(spec, player_at) when is_binary(player_at) and player_at != "" do
    if player_at in List.wrap(spec["player_out_of_reach"]),
      do: spec["player_fallback"],
      else: player_at
  end

  defp player_place(spec, _player_at), do: spec["player_fallback"]

  defp resolve_people(moves, place) when is_map(moves) do
    moves
    |> Enum.map(fn {id, loc} -> {id, swap_player(loc, place)} end)
    |> Enum.reject(fn {_id, loc} -> is_nil(loc) end)
    |> Map.new()
  end

  defp resolve_people(other, _place), do: other

  defp resolve_fact_list(facts, place) when is_list(facts),
    do: Enum.map(facts, &resolve_visibility(&1, place))

  defp resolve_fact_list(other, _place), do: other

  defp resolve_visibility(%{"visibility" => visibility} = fact, place) do
    places =
      visibility
      |> List.wrap()
      |> Enum.map(&swap_player(&1, place))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Map.put(fact, "visibility", places)
  end

  defp resolve_visibility(fact, _place), do: fact

  defp swap_player(@player, place), do: place
  defp swap_player(loc, _place), do: loc

  defp maybe_put_facts(state, facts) when is_list(facts),
    do: Enum.reduce(facts, state, &maybe_put_fact(&2, &1))

  defp maybe_put_facts(state, _facts), do: state

  defp retract_facts(state, ids) when is_list(ids) do
    Map.update(state, "public_facts", [], fn facts ->
      Enum.reject(List.wrap(facts), &(&1["id"] in ids))
    end)
  end

  defp retract_facts(state, _), do: state

  defp maybe_put_status(state, status) when status in ["live", "dormant", "spent"],
    do: Map.put(state, "status", status)

  defp maybe_put_status(state, _), do: state

  # Things the front does to people: WorldSim takes them off the front's
  # runtime and applies them to the people in the same tick.
  defp maybe_queue(state, key, value) when is_map(value) and map_size(value) > 0 do
    Map.update(state, "pending", %{key => value}, fn pending ->
      Map.update(pending, key, value, &Map.merge(&1, value))
    end)
  end

  defp maybe_queue(state, _key, _value), do: state

  defp maybe_set_clocks(state, clocks) when is_map(clocks) do
    Enum.reduce(clocks, state, fn {name, value}, acc ->
      acc
      |> Map.put_new("clocks", %{})
      |> update_in(["clocks"], &Map.put_new(&1, name, %{}))
      |> put_in(["clocks", name, "value"], value)
    end)
  end

  defp maybe_set_clocks(state, _), do: state

  defp maybe_put_fact(state, %{"id" => id} = fact) when is_binary(id) do
    update_in(state, ["public_facts"], &append_unique_fact(&1, stringify_fact(fact)))
  end

  defp maybe_put_fact(state, _), do: state

  defp maybe_put_memory(state, memory) when is_map(memory) do
    entry =
      memory
      |> stringify_memory()
      |> Map.put_new("tick", state["since_tick"])

    update_in(state, ["memories"], &append_memory(&1, entry))
  end

  defp maybe_put_memory(state, _), do: state

  defp stringify_fact(fact) when is_map(fact) do
    %{
      "id" => fact["id"],
      "text" => fact["text"],
      "visibility" => List.wrap(fact["visibility"])
    }
    |> maybe_keep_harm(fact)
  end

  defp stringify_fact(_), do: %{}

  defp maybe_keep_harm(row, %{"harm" => harm}) when is_binary(harm) and harm != "" do
    Map.put(row, "harm", harm)
  end

  defp maybe_keep_harm(row, _), do: row

  defp stringify_memory(memory) when is_map(memory) do
    Map.new(memory, fn {k, v} -> {to_string(k), v} end)
  end

  defp append_memory(nil, memory), do: [memory]
  defp append_memory(list, memory) when is_list(list), do: list ++ [memory]

  defp append_unique_fact(nil, fact), do: [fact]

  defp append_unique_fact(list, fact) when is_list(list) do
    if Enum.any?(list, &(&1["id"] == fact["id"])) do
      list
    else
      list ++ [fact]
    end
  end
end
