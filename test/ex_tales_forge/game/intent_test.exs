defmodule TalesForge.Game.IntentTest do
  use ExUnit.Case, async: false

  alias TalesForge.Game.Intent

  @context %{
    "exits" => ["crossroads_square", "pilgrim_cellar"],
    "exit_names" => %{
      "crossroads_square" => "Crossroads Square",
      "pilgrim_cellar" => "Pilgrim Cellar"
    },
    "present_npcs" => ["marta_kellen"],
    "npc_details" => %{
      "marta_kellen" => %{"name" => "Marta Kellen", "role" => "barkeep"}
    }
  }

  setup do
    previous_provider = System.get_env("LLM_PROVIDER")
    previous_key = System.get_env("XAI_API_KEY")

    on_exit(fn ->
      restore_env("LLM_PROVIDER", previous_provider)
      restore_env("XAI_API_KEY", previous_key)
    end)

    # Live bundle path, but these cases are heuristic-sufficient so no HTTP.
    System.put_env("LLM_PROVIDER", "xai")
    System.put_env("XAI_API_KEY", "test-key")
    :ok
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  test "resolve_bundle uses heuristic for clear observe action" do
    {bundle, source} = Intent.resolve_bundle("look around the tavern", @context)

    assert source == :heuristic
    assert bundle.confidence >= 0.85
    assert hd(bundle.actions).action_type == :observe
  end

  test "resolve_bundle uses heuristic for speak to NPC" do
    {bundle, source} =
      Intent.resolve_bundle("I ask Marta what the chalk marks mean", @context)

    assert source == :heuristic
    assert hd(bundle.actions).action_type == :speak
  end

  test "heuristic treats three days drinking as wait, not spend or drink" do
    {bundle, source} =
      Intent.resolve_bundle(
        "I spend three days drinking and gambling at the inn",
        @context
      )

    action = hd(bundle.actions)
    assert source == :heuristic
    assert action.action_type == :wait
    assert action.parameters["ticks"] == 288
  end

  test "heuristic wait does not steal a mug of ale" do
    {bundle, _} = Intent.resolve_bundle("I drink the ale", @context)
    assert hd(bundle.actions).action_type == :use_item
  end

  test "buy a mug of ale at the inn is buy from innkeep at pack price" do
    context = %{
      "exits" => ["market_square"],
      "exit_names" => %{"market_square" => "Market Square"},
      "present_npcs" => ["innkeep"],
      "npc_details" => %{"innkeep" => %{"name" => "Brenna Holt", "role" => "innkeep"}},
      "npc_stock" => %{
        "innkeep" => [
          %{"id" => "ale_mug", "name" => "Mug of Ale", "price_copper" => 2, "quantity" => 99}
        ]
      }
    }

    {bundle, _} = Intent.resolve_bundle("I buy a mug of ale", context)
    action = hd(bundle.actions)

    assert action.action_type == :buy
    assert action.parameters["item_id"] == "ale_mug"
    assert action.parameters["npc_id"] == "innkeep"
    assert action.parameters["price_copper"] == 2
  end

  @train_context %{
    "exits" => ["market_square"],
    "exit_names" => %{"market_square" => "Market Square"},
    "present_npcs" => ["innkeep"],
    "npc_details" => %{"innkeep" => %{"name" => "Brenna Holt", "role" => "innkeep"}}
  }

  test "heuristic trains persuasion with Brenna for a day" do
    {bundle, source} =
      Intent.resolve_bundle("I train persuasion with Brenna for a day", @train_context)

    action = hd(bundle.actions)
    assert source == :heuristic
    assert action.action_type == :train
    assert action.target == "innkeep"
    assert action.parameters["skill"] == "persuasion"
    assert action.parameters["ticks"] == 96
  end

  test "train wins over wait for a three-day lesson" do
    {bundle, _} =
      Intent.resolve_bundle(
        "I spend three days training persuasion with Brenna",
        @train_context
      )

    action = hd(bundle.actions)
    assert action.action_type == :train
    assert action.target == "innkeep"
    assert action.parameters["skill"] == "persuasion"
    assert action.parameters["ticks"] == 288
  end

  test "train wins over speak when asking a present person to teach" do
    {bundle, _} =
      Intent.resolve_bundle("ask Brenna to teach me persuasion", @train_context)

    action = hd(bundle.actions)
    assert action.action_type == :train
    assert action.target == "innkeep"
    assert action.parameters["skill"] == "persuasion"
  end

  test "practice without a person stays wait" do
    {bundle, _} = Intent.resolve_bundle("I practice stealth for a day", @train_context)
    action = hd(bundle.actions)
    assert action.action_type == :wait
    assert action.parameters["ticks"] == 96
  end
end
