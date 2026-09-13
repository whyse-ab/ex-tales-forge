defmodule TalesForge.Game.InventoryTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.Game.Inventory
  alias TalesForge.Game.Schemas.SingleAction
  alias TalesForge.Game.World
  alias TalesForge.GameSessions
  alias TalesForge.NPC
  alias TalesForge.Repo
  alias TalesForge.Jido
  alias TalesForge.Schemas.Turn

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    :ok
  end

  describe "coin and item primitives" do
    test "coin math" do
      assert Inventory.coin_total_copper(%{"gold" => 1, "silver" => 1, "copper" => 1}) == 511
      assert Inventory.deduct_coins(%{"copper" => 10}, 3) == %{"copper" => 7}
      assert Inventory.coin_total_copper(Inventory.add_coins(%{"copper" => 10}, 5)) == 15
    end

    test "stackable items merge on add and remove" do
      items =
        Inventory.normalize_items([%{"id" => "ale_mug", "name" => "Mug of Ale", "quantity" => 1}])

      items =
        Inventory.add_item(items, %{"id" => "ale_mug", "name" => "Mug of Ale", "quantity" => 2})

      assert Inventory.item_quantity(items, "ale_mug") == 3
      items = Inventory.remove_item(items, "ale_mug", 2)
      assert Inventory.item_quantity(items, "ale_mug") == 1
    end

    test "validate drop requires inventory" do
      character = %{"inventory" => [], "coins" => %{"copper" => 10}}

      assert {:error, _} =
               Inventory.validate_transaction(
                 %SingleAction{
                   action_type: :drop,
                   target: "wooden_shield",
                   parameters: %{"item_id" => "wooden_shield"}
                 },
                 character,
                 [],
                 %{}
               )
    end
  end

  describe "apply_transaction/3" do
    setup do
      world = sample_world()

      {:ok, world: world}
    end

    test "drop moves item from inventory to ground", %{world: world} do
      action = %SingleAction{
        action_type: :drop,
        target: "wooden_shield",
        parameters: %{"item_id" => "wooden_shield", "quantity" => 1}
      }

      assert {:ok, updated, %{applied: applied}} =
               Inventory.apply_transaction(world, "test", action)

      assert "dropped 1x wooden_shield" in applied

      assert Inventory.item_quantity(get_in(updated, ["character", "inventory"]), "wooden_shield") ==
               0

      ground =
        updated
        |> get_in(["locations", "weary_pilgrim", "ground_items"])
        |> Inventory.normalize_items()

      assert Inventory.item_quantity(ground, "wooden_shield") == 1
    end

    test "pickup moves item from ground to inventory", %{world: world} do
      drop = %SingleAction{
        action_type: :drop,
        target: "wooden_shield",
        parameters: %{"item_id" => "wooden_shield", "quantity" => 1}
      }

      {:ok, dropped, _} = Inventory.apply_transaction(world, "test", drop)

      pickup = %SingleAction{
        action_type: :pickup,
        target: "wooden_shield",
        parameters: %{"item_id" => "wooden_shield", "quantity" => 1}
      }

      assert {:ok, updated, %{applied: applied}} =
               Inventory.apply_transaction(dropped, "test", pickup)

      assert "picked up 1x wooden_shield" in applied

      assert Inventory.item_quantity(get_in(updated, ["character", "inventory"]), "wooden_shield") ==
               1
    end

    test "spend deducts coins only", %{world: world} do
      action = %SingleAction{
        action_type: :spend,
        target: "marta_kellen",
        parameters: %{"amount_copper" => 2}
      }

      before = Inventory.coin_total_copper(get_in(world, ["character", "coins"]))

      assert {:ok, updated, %{applied: applied}} =
               Inventory.apply_transaction(world, "test", action)

      assert applied == ["spent 2c"]

      after_total = Inventory.coin_total_copper(get_in(updated, ["character", "coins"]))
      assert after_total == before - 2
      assert length(get_in(updated, ["character", "inventory"])) == 2
    end

    test "failed drop leaves world unchanged", %{world: world} do
      action = %SingleAction{
        action_type: :drop,
        target: "missing_sword",
        parameters: %{"item_id" => "missing_sword", "quantity" => 1}
      }

      assert {:error, _} = Inventory.apply_transaction(world, "test", action)
    end

    test "ground trade exchanges items", %{world: world} do
      world =
        put_in(
          world,
          ["locations", "weary_pilgrim", "ground_items"],
          [
            %{
              "id" => "common_wine",
              "name" => "Bottle of Common Wine",
              "copper_value" => 15,
              "quantity" => 1
            }
          ]
        )

      action = %SingleAction{
        action_type: :trade,
        parameters: %{
          "give" => [%{"id" => "hunting_knife", "quantity" => 1}],
          "receive" => [%{"id" => "common_wine", "quantity" => 1}],
          "counterparty" => "ground"
        }
      }

      assert {:ok, updated, %{applied: applied}} =
               Inventory.apply_transaction(world, "test", action)

      assert Enum.any?(applied, &String.contains?(&1, "gave"))
      assert Enum.any?(applied, &String.contains?(&1, "received"))

      inventory = get_in(updated, ["character", "inventory"]) |> Inventory.normalize_items()

      ground =
        get_in(updated, ["locations", "weary_pilgrim", "ground_items"])
        |> Inventory.normalize_items()

      assert Inventory.item_quantity(inventory, "hunting_knife") == 0
      assert Inventory.item_quantity(inventory, "common_wine") == 1
      assert Inventory.item_quantity(ground, "hunting_knife") == 1
      assert Inventory.item_quantity(ground, "common_wine") == 0
    end
  end

  describe "buy with NPC stock" do
    test "buy deducts coins and adds item" do
      {:ok, session} = GameSessions.create_session(%{name: "Inventory Buy"})
      world = session.world_state

      action = %SingleAction{
        action_type: :buy,
        target: "marta_kellen",
        parameters: %{
          "item_id" => "ale_mug",
          "quantity" => 1,
          "price_copper" => 2,
          "npc_id" => "marta_kellen"
        }
      }

      before = Inventory.coin_total_copper(get_in(world, ["character", "coins"]))

      assert {:ok, updated, %{applied: applied}} =
               Inventory.apply_transaction(world, session.id, action)

      assert Enum.any?(applied, &String.contains?(&1, "bought"))

      after_total = Inventory.coin_total_copper(get_in(updated, ["character", "coins"]))
      assert after_total == before - 2

      inventory = get_in(updated, ["character", "inventory"]) |> Inventory.normalize_items()
      assert Inventory.item_quantity(inventory, "ale_mug") == 1

      stock = NPC.stock_map(session.id, ["marta_kellen"])["marta_kellen"]
      assert Inventory.item_quantity(stock, "ale_mug") == 98
    end

    test "buy ale_mug from innkeep deducts 2c" do
      {:ok, session} =
        GameSessions.create_session(%{name: "Tin Valley Mug", adventure_id: "tin_valley"})

      world = session.world_state

      action = %SingleAction{
        action_type: :buy,
        target: "innkeep",
        parameters: %{
          "item_id" => "ale_mug",
          "quantity" => 1,
          "price_copper" => 2,
          "npc_id" => "innkeep"
        }
      }

      before = Inventory.coin_total_copper(get_in(world, ["character", "coins"]))

      assert {:ok, updated, %{applied: applied}} =
               Inventory.apply_transaction(world, session.id, action)

      assert Enum.any?(applied, &String.contains?(&1, "bought"))

      after_total = Inventory.coin_total_copper(get_in(updated, ["character", "coins"]))
      assert after_total == before - 2

      inventory = get_in(updated, ["character", "inventory"]) |> Inventory.normalize_items()
      assert Inventory.item_quantity(inventory, "ale_mug") == 1

      stock = NPC.stock_map(session.id, ["innkeep"])["innkeep"]
      assert Inventory.item_quantity(stock, "ale_mug") == 98
    end
  end

  describe "turn integration" do
    test "submit drop action updates ground items in persisted world state" do
      {:ok, session} = GameSessions.create_session(%{name: "Inventory Drop"})

      assert {:ok, %{status: :processing}} =
               GameSessions.submit_message(session.id, "drop my hunting knife")

      session = GameSessions.get_session!(session.id)

      inventory =
        get_in(session.world_state, ["character", "inventory"]) |> Inventory.normalize_items()

      ground =
        get_in(session.world_state, ["locations", "weary_pilgrim", "ground_items"])
        |> Inventory.normalize_items()

      assert Inventory.item_quantity(inventory, "hunting_knife") == 0
      assert Inventory.item_quantity(ground, "hunting_knife") == 1

      [turn] = Turn |> Repo.all() |> Enum.filter(&(&1.game_session_id == session.id))
      assert turn.player_action == "drop my hunting knife"
    end
  end

  defp sample_world do
    World.default_world_state()
    |> put_in(
      ["character", "inventory"],
      [
        %{
          "id" => "wooden_shield",
          "name" => "Wooden Shield",
          "copper_value" => 80,
          "quantity" => 1
        },
        %{
          "id" => "hunting_knife",
          "name" => "Hunting Knife",
          "copper_value" => 100,
          "quantity" => 1
        }
      ]
    )
    |> put_in(["character", "coins"], %{"copper" => 50})
  end
end
