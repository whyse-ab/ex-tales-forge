defmodule TalesForge.LLMTest do
  use ExUnit.Case, async: false

  doctest TalesForge.LLM

  alias TalesForge.LLM

  setup do
    on_exit(fn ->
      for {key, _} <- System.get_env(), String.starts_with?(key, "XAI_") do
        System.delete_env(key)
      end

      System.delete_env("TIER1_MODEL")
      System.delete_env("TIER2_MODEL")
    end)

    :ok
  end

  test "tier1_model prefers xai over ollama when XAI_API_KEY is set" do
    System.put_env("XAI_API_KEY", "test-key")
    System.put_env("XAI_MODEL", "grok-4.20-0309-non-reasoning")

    assert LLM.tier1_model() == "xai/grok-4.20-0309-non-reasoning"
    assert LLM.tier2_model() == "xai/grok-4.20-0309-non-reasoning"
  end

  test "effective_xai_model rejects reasoning models" do
    System.put_env("XAI_MODEL", "grok-4.20-0309-reasoning")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert LLM.effective_xai_model() == "grok-4.20-0309-non-reasoning"
      end)

    assert log =~ "reasoning model"
  end
end
