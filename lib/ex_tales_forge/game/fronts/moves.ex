defmodule TalesForge.Game.Fronts.Moves do
  @moduledoc """
  Server-enforced legal move palette. Pure — no Repo.
  """

  require Logger

  @spec apply(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def apply(runtime_state, "raise_alert", pack_def) when is_map(runtime_state) do
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

  def apply(runtime_state, "hire_extra", pack_def) when is_map(runtime_state) do
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

  def apply(runtime_state, "mark_debt", pack_def) when is_map(runtime_state) do
    memory = get_in(pack_def, ["moves", "mark_debt", "memory"]) || %{"felt" => "owed"}
    {:ok, maybe_put_memory(runtime_state, memory)}
  end

  def apply(_runtime_state, "unknown_front_probe", _pack_def) do
    {:error, :unknown_move}
  end

  def apply(_runtime_state, move, _pack_def) when is_binary(move) do
    raise ArgumentError, "unknown legal move #{inspect(move)}"
  end

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
  end

  defp stringify_fact(_), do: %{}

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
