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
end
