defmodule TalesForge.World.Prices do
  @moduledoc """
  World agents round 2: prices come from code, not from the GM.

  After the rules step, for the price facts of the place the character is in
  (and the persons present) that the player's words mention:

  - if the action is a payment or purchase ("I pay", "slide two coppers",
    "buy", "rent", "I'll take the room"), the server charges the listed price
    from the character's coins: `Purchase: Bowl of stew, 5 copper, paid`;
  - if the character can't afford it: `... not paid (has 3 copper)`;
  - otherwise it is a price the GM must quote: `Price: Private room, one night, 3 silver`.

  A purchase the inventory handler already made from an NPC's stock (coins went
  down this turn) is reported as is and nothing is charged twice.

  The lines go to the GM in the per-turn section (`prompt_section/1`) only.
  Pure functions: the caller puts the returned world into the turn's board.
  """

  alias TalesForge.Game.Inventory

  @max_items 3
  @pay ~r/\b(pay|pays|paid|paying|buy|buys|bought|purchase|purchases|rent|rents|order|orders|i'?ll take|i'?ll have|take the room)\b/i
  @hand_over ~r/\b(slide|slides|slid|place|places|hand|hands|count out|counts out|set down|sets down|offer|offers|give|gives|push|pushes)\b/i
  @coin_word ~r/\b(copper|coppers|silver|silvers|gold|coin|coins)\b/i
  @amount ~r/\b(\d+|a|one|two|three|four|five|six|seven|eight|nine|ten)\s+(copper|coppers|silver|silvers|gold)\b/i

  @doc """
  Resolves this turn's prices. `world_before` is the session state before the
  rules step, `world` after it. Returns `{world, lines}`.
  """
  def resolve(agents, world_before, world, raw_action, player_action) do
    spent = coins(world_before) - coins(world)

    if spent > 0 and bought?(player_action) do
      item = Map.get(primary(player_action).parameters || %{}, "item_id") || "item"
      {world, ["Purchase: #{item}, #{money(spent)}, paid (server, from the seller's stock)"]}
    else
      agents
      |> price_facts()
      |> mentioned(raw_action)
      |> Enum.take(@max_items)
      |> Enum.reduce({world, []}, fn fact, {w, lines} ->
        {w, line} = resolve_one(w, fact, payment?(raw_action, player_action))
        {w, lines ++ [line]}
      end)
    end
  end

  defp resolve_one(world, fact, true) do
    have = coins(world)
    price = fact["copper"]

    if have >= price do
      world =
        update_in(world, ["character"], fn c ->
          Map.put(
            c || %{},
            "coins",
            Inventory.deduct_coins(Map.get(c || %{}, "coins", %{}), price)
          )
        end)

      {world, "Purchase: #{fact["item"]}, #{money(price)}, paid (server)"}
    else
      {world, "Purchase: #{fact["item"]}, #{money(price)}, not paid (has #{money(have)})"}
    end
  end

  defp resolve_one(world, fact, false),
    do: {world, "Price: #{fact["item"]}, #{money(fact["copper"])}"}

  @doc "Per-turn prompt section for the lines, or nil."
  def prompt_section([]), do: nil
  def prompt_section(nil), do: nil

  def prompt_section(lines),
    do:
      Enum.join(
        [
          "## Prices this turn (from the server; use these exact amounts)"
          | Enum.map(lines, &("- " <> &1))
        ],
        "\n"
      )

  @doc false
  def price_facts(agents) do
    agents
    |> Enum.filter(&(&1.role in [:here, :present]))
    |> Enum.flat_map(& &1.facts)
    |> Enum.filter(
      &(&1["kind"] == "price" and is_integer(&1["copper"]) and is_binary(&1["item"]))
    )
  end

  @doc false
  def mentioned(facts, raw_action) do
    text = String.downcase(to_string(raw_action))

    Enum.filter(facts, fn fact ->
      # "not_when": phrases that use an alias for something else ("the common room").
      text = Enum.reduce(fact["not_when"] || [], text, &String.replace(&2, &1, " "))

      Enum.any?(fact["aliases"] || [String.downcase(fact["item"])], fn a ->
        Regex.match?(~r/\b#{Regex.escape(String.downcase(a))}s?\b/, text)
      end)
    end)
  end

  @doc false
  def payment?(raw_action, player_action) do
    text = to_string(raw_action)
    coins_over? = Regex.match?(@hand_over, text) and Regex.match?(@coin_word, text)

    # A question ("Could I pay for a room?", "Two copper?") is still asking; a
    # statement that pays or names the amount ("Two copper it is for the ale.",
    # "I slide two coppers over. Enough?") is paying.
    statements =
      ~r/(?<=[.!?;])\s+/
      |> Regex.split(text, trim: true)
      |> Enum.reject(&String.ends_with?(String.trim(&1), "?"))

    bought?(player_action) or coins_over? or
      Enum.any?(statements, &(Regex.match?(@pay, &1) or Regex.match?(@amount, &1)))
  end

  defp bought?(player_action), do: action_type(player_action) in [:buy, :spend, :trade]

  defp primary(%{action: %{} = a}), do: a
  defp primary(_), do: %{action_type: nil, parameters: %{}}

  defp action_type(player_action) do
    case primary(player_action) do
      %{action_type: t} -> t
      _ -> nil
    end
  end

  defp coins(world),
    do: Inventory.coin_total_copper(get_in(world || %{}, ["character", "coins"]) || %{})

  @doc ~s(Copper as the coins a person would say: 30 -> "3 silver", 35 -> "3 silver 5 copper".)
  def money(copper) when is_integer(copper) do
    gold = div(copper, 500)
    silver = div(rem(copper, 500), 10)
    cp = rem(copper, 10)

    [{gold, "gold"}, {silver, "silver"}, {cp, "copper"}]
    |> Enum.reject(fn {n, _} -> n == 0 end)
    |> Enum.map_join(" ", fn {n, unit} -> "#{n} #{unit}" end)
    |> case do
      "" -> "0 copper"
      s -> s
    end
  end
end
