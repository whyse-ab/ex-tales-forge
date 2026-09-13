defmodule TalesForge.Game.Inventory do
  @moduledoc false

  alias TalesForge.Game.Schemas.SingleAction
  alias TalesForge.Game.World
  alias TalesForge.NPC

  @inventory_actions ~w(pickup drop buy sell trade spend)a

  @copper_per_silver 10
  @copper_per_gold 500

  def inventory_actions, do: @inventory_actions

  def apply_server_inventory(world_state, session_id, action, handler) do
    if handler.handler == "inventory" and action.action_type in @inventory_actions do
      apply_transaction(world_state, session_id, action)
    else
      {:ok, world_state, nil}
    end
  end

  def apply_transaction(world_state, session_id, %SingleAction{} = action) do
    location_id = get_in(world_state, ["character", "location_id"]) || "weary_pilgrim"
    character = Map.get(world_state, "character", %{})
    ground_items = ground_items_for(world_state, location_id)
    present_npcs = Map.get(world_state, "present_npcs", [])
    npc_stock = NPC.stock_map(session_id, npc_stock_keys(action, present_npcs))

    resolved = resolve_action(action, character, ground_items, npc_stock)

    case validate_transaction(resolved, character, ground_items, npc_stock) do
      :ok ->
        do_apply(
          world_state,
          session_id,
          location_id,
          resolved,
          character,
          ground_items,
          npc_stock
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  def validate_transaction(%SingleAction{} = action, character, ground_items, npc_stock) do
    params = action.parameters || %{}
    inventory = normalize_items(Map.get(character, "inventory", []))

    case action.action_type do
      :drop ->
        with item_id when item_id != "" <- item_ref(action),
             true <- item_quantity(inventory, item_id) >= action_quantity(params) do
          :ok
        else
          "" -> {:error, "Drop requires an item_id target."}
          false -> {:error, "Cannot drop '#{item_ref(action)}' — not in inventory."}
        end

      :pickup ->
        with item_id when item_id != "" <- item_ref(action),
             true <- item_quantity(ground_items, item_id) >= action_quantity(params) do
          :ok
        else
          "" -> {:error, "Pickup requires an item_id target."}
          false -> {:error, "Cannot pick up '#{item_ref(action)}' — not on the ground here."}
        end

      :buy ->
        validate_buy(action, params, character, npc_stock)

      :sell ->
        item_id = Map.get(params, "item_id", "") |> to_string() |> String.trim()
        qty = action_quantity(params)
        npc_id = npc_ref(action, "")

        cond do
          item_id == "" ->
            {:error, "Sell requires parameters.item_id."}

          npc_id == "" ->
            {:error, "Sell requires an NPC target."}

          item_quantity(inventory, item_id) < qty ->
            {:error, "Cannot sell '#{item_id}' — not in inventory."}

          true ->
            :ok
        end

      :spend ->
        amount = spend_amount(action)

        cond do
          amount <= 0 ->
            {:error, "Spend requires parameters.amount_copper."}

          coin_total_copper(Map.get(character, "coins", %{})) < amount ->
            {:error, "Insufficient funds (need #{amount}c)."}

          true ->
            :ok
        end

      :trade ->
        with {:ok, give_items, receive_items, counterparty} <- trade_legs(params),
             :ok <- validate_trade_give(inventory, give_items),
             :ok <- validate_trade_receive(receive_items, counterparty, ground_items, npc_stock) do
          :ok
        else
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, "Not an inventory action."}
    end
  end

  defp validate_buy(action, params, character, npc_stock) do
    item_id = Map.get(params, "item_id", "") |> to_string() |> String.trim()
    qty = action_quantity(params)
    npc_id = resolve_buy_npc_id(action, params, npc_stock)
    stock = normalize_stock(Map.get(npc_stock, npc_id, []))
    stock_item = Enum.find(stock, &(&1["id"] == item_id))

    cond do
      item_id == "" ->
        {:error, "Buy requires parameters.item_id."}

      npc_id == "" or is_nil(stock_item) ->
        {:error, "'#{item_id}' is not sold here."}

      item_quantity(stock, item_id) < qty ->
        {:error, "Not enough '#{item_id}' in stock."}

      coin_total_copper(Map.get(character, "coins", %{})) <
          price_copper(params, stock_item) * qty ->
        {:error,
         "Insufficient funds for #{item_id} (#{price_copper(params, stock_item) * qty}c needed)."}

      true ->
        :ok
    end
  end

  def normalize_stock(raw) when is_list(raw) do
    Enum.flat_map(raw, fn
      %{} = entry ->
        item_id = entry |> Map.get("id", "") |> to_string() |> String.trim()

        if item_id == "" do
          []
        else
          [
            %{
              "id" => item_id,
              "name" => default_name(entry, item_id),
              "price_copper" => int_field(entry, ["price_copper", "copper_value"], 0),
              "quantity" => max(1, int_field(entry, ["quantity"], 1))
            }
          ]
        end

      _ ->
        []
    end)
  end

  def normalize_stock(_), do: []

  def normalize_items(raw) when is_list(raw) do
    Enum.flat_map(raw, fn
      %{} = entry ->
        item_id = entry |> Map.get("id", "") |> to_string() |> String.trim()

        if item_id == "" do
          []
        else
          [
            %{
              "id" => item_id,
              "name" => default_name(entry, item_id),
              "copper_value" => int_field(entry, ["copper_value"], 0),
              "quantity" => max(1, int_field(entry, ["quantity"], 1))
            }
          ]
        end

      _ ->
        []
    end)
  end

  def normalize_items(_), do: []

  def item_quantity(items, item_id) do
    case find_item_index(items, item_id) do
      nil -> 0
      index -> int_field(Enum.at(items, index), ["quantity"], 0)
    end
  end

  def add_item(items, item) when is_map(item) do
    item_id = Map.fetch!(item, "id")
    qty = max(1, int_field(item, ["quantity"], 1))

    case find_item_index(items, item_id) do
      nil ->
        items ++ [Map.put(item, "quantity", qty)]

      index ->
        current = int_field(Enum.at(items, index), ["quantity"], 0)
        List.replace_at(items, index, Map.put(Enum.at(items, index), "quantity", current + qty))
    end
  end

  def remove_item(items, item_id, quantity \\ 1) do
    index = find_item_index(items, item_id)

    if is_nil(index) do
      raise ArgumentError, "Item '#{item_id}' not found."
    end

    current = int_field(Enum.at(items, index), ["quantity"], 0)

    if current < quantity do
      raise ArgumentError, "Not enough '#{item_id}' (have #{current}, need #{quantity})."
    end

    remaining = current - quantity

    if remaining <= 0 do
      List.delete_at(items, index)
    else
      List.replace_at(items, index, Map.put(Enum.at(items, index), "quantity", remaining))
    end
  end

  def coin_total_copper(coins) when is_map(coins) do
    gold = int_field(coins, ["gold"], 0)
    silver = int_field(coins, ["silver"], 0)
    copper = int_field(coins, ["copper"], 0)
    gold * @copper_per_gold + silver * @copper_per_silver + copper
  end

  def coin_total_copper(_), do: 0

  def deduct_coins(coins, amount_copper) do
    total = coin_total_copper(coins)

    if total < amount_copper do
      raise ArgumentError, "Insufficient funds (have #{total}c, need #{amount_copper}c)."
    end

    copper_to_coins(total - amount_copper)
  end

  def add_coins(coins, amount_copper) do
    copper_to_coins(coin_total_copper(coins) + amount_copper)
  end

  def resolve_item_id(hint, items) when is_binary(hint) do
    hint = String.trim(hint)
    normalized = String.downcase(hint)

    cond do
      hint == "" -> nil
      match = Enum.find(items, &(&1["id"] == normalized)) -> match["id"]
      true -> Enum.find_value(items, &matching_item_id(normalized, &1))
    end
  end

  def resolve_item_id(_, _), do: nil

  defp matching_item_id(normalized, item) do
    id = item["id"]
    name = String.downcase(Map.get(item, "name", id))
    readable = String.replace(String.downcase(id), "_", " ")

    if item_name_matches?(normalized, readable, name), do: id
  end

  defp item_name_matches?(normalized, readable, name) do
    String.contains?(normalized, readable) or String.contains?(readable, normalized) or
      String.contains?(normalized, name) or String.contains?(name, normalized)
  end

  defp do_apply(world_state, session_id, location_id, action, character, ground_items, npc_stock) do
    params = action.parameters || %{}
    inventory = normalize_items(Map.get(character, "inventory", []))
    coins = Map.get(character, "coins", %{})

    try do
      {inventory, ground_items, coins, applied, npc_updates} =
        case action.action_type do
          :drop ->
            item_id = item_ref(action)
            qty = action_quantity(params)
            source = Enum.at(inventory, find_item_index(inventory, item_id))

            {
              remove_item(inventory, item_id, qty),
              add_item(ground_items, %{
                "id" => item_id,
                "name" => source["name"],
                "copper_value" => Map.get(source, "copper_value", 0),
                "quantity" => qty
              }),
              coins,
              ["dropped #{qty}x #{item_id}"],
              %{}
            }

          :pickup ->
            item_id = item_ref(action)
            qty = action_quantity(params)
            source = Enum.at(ground_items, find_item_index(ground_items, item_id))

            {
              add_item(inventory, %{
                "id" => item_id,
                "name" => source["name"],
                "copper_value" => Map.get(source, "copper_value", 0),
                "quantity" => qty
              }),
              remove_item(ground_items, item_id, qty),
              coins,
              ["picked up #{qty}x #{item_id}"],
              %{}
            }

          :buy ->
            item_id = Map.get(params, "item_id", "") |> to_string() |> String.trim()
            qty = action_quantity(params)
            npc_id = resolve_buy_npc_id(action, params, npc_stock)
            stock = normalize_stock(Map.get(npc_stock, npc_id, []))
            stock_item = Enum.find(stock, &(&1["id"] == item_id))
            price = price_copper(params, stock_item)
            total = price * qty

            {
              add_item(inventory, %{
                "id" => item_id,
                "name" => stock_item["name"],
                "copper_value" => price,
                "quantity" => qty
              }),
              ground_items,
              deduct_coins(coins, total),
              ["bought #{qty}x #{item_id} for #{total}c"],
              %{npc_id => remove_item(stock, item_id, qty)}
            }

          :sell ->
            item_id = Map.get(params, "item_id", "") |> to_string() |> String.trim()
            qty = action_quantity(params)
            price = int_field(params, ["price_copper"], 0)

            {
              remove_item(inventory, item_id, qty),
              ground_items,
              add_coins(coins, price * qty),
              ["sold #{qty}x #{item_id} for #{price * qty}c"],
              %{}
            }

          :spend ->
            amount = spend_amount(action)

            {
              inventory,
              ground_items,
              deduct_coins(coins, amount),
              ["spent #{amount}c"],
              %{}
            }

          :trade ->
            {:ok, give_items, receive_items, counterparty} = trade_legs(params)

            apply_trade(
              inventory,
              ground_items,
              coins,
              give_items,
              receive_items,
              counterparty,
              npc_stock
            )
        end

      :ok = NPC.persist_stock_updates(session_id, npc_updates)

      character =
        character
        |> Map.put("inventory", inventory)
        |> Map.put("coins", coins)

      world_state =
        world_state
        |> put_in(["character"], character)
        |> put_ground_items(location_id, ground_items)

      {:ok, world_state, %{applied: applied}}
    rescue
      error in ArgumentError ->
        {:error, Exception.message(error)}
    end
  end

  defp apply_trade(
         inventory,
         ground_items,
         coins,
         give_items,
         receive_items,
         counterparty,
         npc_stock
       ) do
    {inventory, ground_items, applied_give} =
      Enum.reduce(give_items, {inventory, ground_items, []}, fn leg, {inv, ground, applied} ->
        source = Enum.at(inv, find_item_index(inv, leg["id"]))
        inv = remove_item(inv, leg["id"], leg["quantity"])

        ground =
          if counterparty == "ground" do
            add_item(ground, %{
              "id" => leg["id"],
              "name" => source["name"],
              "copper_value" => Map.get(source, "copper_value", 0),
              "quantity" => leg["quantity"]
            })
          else
            ground
          end

        {inv, ground, applied ++ ["gave #{leg["quantity"]}x #{leg["id"]}"]}
      end)

    if counterparty == "ground" do
      {inventory, ground_items, applied_receive} =
        Enum.reduce(receive_items, {inventory, ground_items, []}, fn leg,
                                                                     {inv, ground, applied} ->
          source = Enum.at(ground, find_item_index(ground, leg["id"]))
          ground = remove_item(ground, leg["id"], leg["quantity"])

          inv =
            add_item(inv, %{
              "id" => leg["id"],
              "name" => source["name"],
              "copper_value" => Map.get(source, "copper_value", 0),
              "quantity" => leg["quantity"]
            })

          {inv, ground, applied ++ ["received #{leg["quantity"]}x #{leg["id"]} from ground"]}
        end)

      {inventory, ground_items, coins, applied_give ++ applied_receive, %{}}
    else
      stock = normalize_stock(Map.get(npc_stock, counterparty, []))

      {inventory, stock, applied_receive} =
        Enum.reduce(receive_items, {inventory, stock, []}, fn leg, {inv, stk, applied} ->
          source = Enum.at(stk, find_item_index(stk, leg["id"]))
          stk = remove_item(stk, leg["id"], leg["quantity"])

          inv =
            add_item(inv, %{
              "id" => leg["id"],
              "name" => source["name"],
              "copper_value" => price_copper(%{}, source),
              "quantity" => leg["quantity"]
            })

          {inv, stk,
           applied ++ ["received #{leg["quantity"]}x #{leg["id"]} from #{counterparty}"]}
        end)

      {inventory, ground_items, coins, applied_give ++ applied_receive, %{counterparty => stock}}
    end
  end

  defp resolve_action(action, character, ground_items, npc_stock) do
    params = action.parameters || %{}
    inventory = normalize_items(Map.get(character, "inventory", []))

    resolved_params =
      case action.action_type do
        :drop ->
          item_id =
            Map.get(params, "item_id") ||
              resolve_item_id(to_string(action.target || ""), inventory)

          Map.put(params, "item_id", item_id || "")

        :pickup ->
          item_id =
            Map.get(params, "item_id") ||
              resolve_item_id(to_string(action.target || ""), ground_items)

          Map.put(params, "item_id", item_id || "")

        :buy ->
          named_npc = npc_ref(action, "")

          stock_items =
            if named_npc == "" do
              npc_stock |> Map.values() |> List.flatten() |> normalize_stock()
            else
              normalize_stock(Map.get(npc_stock, named_npc, []))
            end

          item_id =
            Map.get(params, "item_id") ||
              resolve_item_id(to_string(action.target || ""), stock_items)

          npc_id =
            if named_npc == "" do
              seller_for_item(npc_stock, item_id || "") || ""
            else
              named_npc
            end

          params
          |> Map.put("item_id", item_id || "")
          |> Map.put("npc_id", npc_id)

        :sell ->
          item_id =
            Map.get(params, "item_id") ||
              resolve_item_id(to_string(action.target || ""), inventory)

          Map.put(params, "item_id", item_id || "")

        :spend ->
          amount = spend_amount(%{action | parameters: params})
          Map.put(params, "amount_copper", amount)

        _ ->
          params
      end

    target =
      case action.action_type do
        type when type in [:drop, :pickup] ->
          Map.get(params, "item_id") || action.target

        _ ->
          action.target
      end

    %{action | parameters: resolved_params, target: target}
  end

  defp ground_items_for(world_state, location_id) do
    world_state
    |> World.runtime_location(location_id)
    |> Map.get("ground_items", [])
    |> normalize_items()
  end

  defp put_ground_items(world_state, location_id, ground_items) do
    location = World.runtime_location(world_state, location_id)
    updated = Map.put(location, "ground_items", ground_items)
    put_in(world_state, ["locations", location_id], updated)
  end

  defp item_ref(%SingleAction{} = action) do
    params = action.parameters || %{}

    (Map.get(params, "item_id") || action.target || "")
    |> to_string()
    |> String.trim()
  end

  defp npc_ref(%SingleAction{} = action, default) do
    params = action.parameters || %{}

    (Map.get(params, "npc_id") || action.target || default)
    |> to_string()
    |> String.trim()
  end

  defp resolve_buy_npc_id(action, params, npc_stock) do
    case npc_ref(%{action | parameters: params}, "") do
      "" ->
        item_id = params |> Map.get("item_id", "") |> to_string() |> String.trim()
        seller_for_item(npc_stock, item_id) || ""

      npc_id ->
        npc_id
    end
  end

  defp seller_for_item(_npc_stock, ""), do: nil

  defp seller_for_item(npc_stock, item_id) when is_map(npc_stock) and is_binary(item_id) do
    Enum.find_value(npc_stock, fn {npc_id, stock} ->
      if item_quantity(normalize_stock(stock), item_id) > 0, do: to_string(npc_id)
    end)
  end

  defp seller_for_item(_, _), do: nil

  defp action_quantity(params) do
    max(1, int_field(params, ["quantity"], 1))
  end

  defp spend_amount(%SingleAction{} = action) do
    params = action.parameters || %{}

    case int_field(params, ["amount_copper"], 0) do
      amount when amount > 0 ->
        amount

      _ ->
        parse_copper_hint(to_string(action.target || ""))
    end
  end

  def parse_copper_hint(text) when is_binary(text) do
    case Regex.run(~r/(\d+)\s*c(?:opper)?\b/i, text) do
      [_, digits] -> String.to_integer(digits)
      _ -> 0
    end
  end

  defp price_copper(params, stock_item) do
    case int_field(params, ["price_copper"], 0) do
      0 -> int_field(stock_item, ["price_copper", "copper_value"], 0)
      price -> price
    end
  end

  defp trade_legs(params) do
    give = Map.get(params, "give", [])
    receive = Map.get(params, "receive", [])
    counterparty = Map.get(params, "counterparty", "ground") |> to_string() |> String.trim()

    cond do
      not is_list(give) or not is_list(receive) ->
        {:error, "Trade requires give and receive item lists."}

      give == [] or receive == [] ->
        {:error, "Trade requires at least one item to give and one to receive."}

      true ->
        {:ok, normalize_items(give), normalize_items(receive), counterparty || "ground"}
    end
  end

  defp validate_trade_give(inventory, give_items) do
    Enum.reduce_while(give_items, :ok, fn leg, _acc ->
      if item_quantity(inventory, leg["id"]) < leg["quantity"] do
        {:halt, {:error, "Cannot trade away '#{leg["id"]}' — not in inventory."}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp validate_trade_receive(receive_items, "ground", ground_items, _npc_stock) do
    Enum.reduce_while(receive_items, :ok, fn leg, _acc ->
      if item_quantity(ground_items, leg["id"]) < leg["quantity"] do
        {:halt, {:error, "Cannot receive '#{leg["id"]}' — not on the ground here."}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp validate_trade_receive(receive_items, counterparty, _ground_items, npc_stock) do
    stock = normalize_stock(Map.get(npc_stock, counterparty, []))

    Enum.reduce_while(receive_items, :ok, fn leg, _acc ->
      if item_quantity(stock, leg["id"]) < leg["quantity"] do
        {:halt, {:error, "Cannot receive '#{leg["id"]}' from #{counterparty}."}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp npc_stock_keys(%SingleAction{action_type: :buy} = action, present_npcs) do
    case npc_ref(action, "") do
      "" -> present_npcs
      npc_id -> Enum.uniq([npc_id | List.wrap(present_npcs)])
    end
  end

  defp npc_stock_keys(%SingleAction{action_type: :trade} = action, _present_npcs) do
    params = action.parameters || %{}
    counterparty = params |> Map.get("counterparty", "ground") |> to_string() |> String.trim()

    if counterparty in ["", "ground"], do: [], else: [counterparty]
  end

  defp npc_stock_keys(_action, _present_npcs), do: []

  defp find_item_index(items, item_id) do
    Enum.find_index(items, &(&1["id"] == item_id))
  end

  defp copper_to_coins(total) do
    total = max(0, total)
    gold = div(total, @copper_per_gold)
    after_gold = rem(total, @copper_per_gold)
    silver = div(after_gold, @copper_per_silver)
    copper = rem(after_gold, @copper_per_silver)

    %{}
    |> maybe_put("gold", gold)
    |> maybe_put("silver", silver)
    |> maybe_put("copper", copper)
  end

  defp maybe_put(map, _key, 0), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp default_name(entry, item_id) do
    case Map.get(entry, "name") do
      name when is_binary(name) and name != "" -> name
      _ -> item_id |> String.replace("_", " ") |> String.capitalize()
    end
  end

  defp int_field(map, keys, default) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        nil -> nil
        value when is_integer(value) -> value
        value when is_binary(value) -> String.to_integer(value)
        value when is_float(value) -> trunc(value)
        _ -> nil
      end
    end) || default
  end

  defp int_field(_, _, default), do: default
end
