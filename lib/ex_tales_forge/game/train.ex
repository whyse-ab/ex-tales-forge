defmodule TalesForge.Game.Train do
  @moduledoc false

  alias TalesForge.Game.Inventory
  alias TalesForge.Game.Mechanics
  alias TalesForge.Game.WorldClock

  def apply(character, npc_def, present_ids, action, opts \\ []) do
    params = action.parameters || %{}
    skill = Mechanics.normalize_skill_name(Map.get(params, "skill"))
    ticks = WorldClock.clamp_wait(Map.get(params, "ticks"))
    npc_id = action.target

    case qualify(character, npc_def, present_ids, skill, ticks) do
      {:ok, fee} ->
        rolls = opts[:improvement_rolls] || %{}
        {taught, [entry]} = Mechanics.attempt_trained_skill(character, skill, rolls)
        coins = Inventory.deduct_coins(Map.get(taught, "coins", %{}), fee)
        taught = Map.put(taught, "coins", coins)
        {taught, [Map.put(entry, "trainer_npc_id", npc_id)], "took_place", ticks}

      {:error, _} ->
        {character, [], "declined", 1}
    end
  end

  def qualify(character, npc_def, present_ids, skill, ticks) do
    npc_id = Map.get(npc_def || %{}, "id")
    npc_skill = get_in(npc_def || %{}, ["skills", skill])
    fee_rate = Map.get(npc_def || %{}, "fee_copper")
    raw = character |> get_in(["skills", skill]) |> to_int(0)
    vitality = training_vitality(character)
    coins = Map.get(character, "coins", %{})

    cond do
      not is_binary(skill) or skill == "" ->
        {:error, :no_skill}

      not is_binary(npc_id) or npc_id == "" ->
        {:error, :no_npc}

      npc_id not in List.wrap(present_ids) ->
        {:error, :not_present}

      not is_integer(npc_skill) ->
        {:error, :no_skill_rating}

      npc_skill < raw + 5 ->
        {:error, :gap}

      not (is_integer(fee_rate) and fee_rate > 0) ->
        {:error, :no_fee}

      Inventory.coin_total_copper(coins) < session_fee(fee_rate, ticks) ->
        {:error, :cannot_pay}

      vitality not in ["ok", "hurt"] ->
        {:error, :vitality}

      not Mechanics.skill_eligible?(character, skill) ->
        {:error, :not_eligible}

      true ->
        {:ok, session_fee(fee_rate, ticks)}
    end
  end

  def session_fee(fee_copper, ticks) when is_integer(fee_copper) and fee_copper > 0 do
    days = max(1, ceil(ticks / WorldClock.ticks_per_day()))
    fee_copper * days
  end

  # Stamped down/dead without wounding — Mechanics.vitality/1 derives down from wounds.
  defp training_vitality(character) do
    case Map.get(character, "vitality") do
      vitality when vitality in ["down", "dead"] -> vitality
      _ -> Mechanics.vitality(character)
    end
  end

  defp to_int(value, _default) when is_integer(value), do: value
  defp to_int(value, _default) when is_float(value), do: trunc(value)
  defp to_int(_, default), do: default
end
