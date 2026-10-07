defmodule TalesForge.Config do
  @moduledoc """
  Runtime configuration loaded from environment variables.
  """

  def llm_provider do
    case blank_to_nil(System.get_env("LLM_PROVIDER")) do
      nil -> auto_provider()
      value -> String.downcase(value)
    end
  end

  def xai_api_key, do: System.get_env("XAI_API_KEY", "")
  def openai_api_key, do: System.get_env("OPENAI_API_KEY", "")
  def anthropic_api_key, do: System.get_env("ANTHROPIC_API_KEY", "")
  @default_xai_model "grok-4.20-0309-non-reasoning"

  def xai_model, do: System.get_env("XAI_MODEL", @default_xai_model)
  def default_xai_model, do: @default_xai_model

  def tier1_model, do: blank_to_nil(System.get_env("TIER1_MODEL"))
  def tier2_model, do: blank_to_nil(System.get_env("TIER2_MODEL"))

  def tier1_temperature, do: env_float("TIER1_TEMPERATURE", 0.0)
  def tier2_temperature, do: env_float("TIER2_TEMPERATURE", 0.7)
  def tier1_confidence_threshold, do: env_float("TIER1_CONFIDENCE_THRESHOLD", 0.75)
  def tier1_heuristic_threshold, do: env_float("TIER1_HEURISTIC_THRESHOLD", 0.85)
  def tier1_max_tokens, do: env_int("TIER1_MAX_TOKENS", 400)
  def tier2_max_tokens, do: env_int("TIER2_MAX_TOKENS", 700)

  @doc "NPC reaction prototype (Jev, before the GM call): NPC_REACTIONS=on. Default off."
  def npc_reactions?, do: System.get_env("NPC_REACTIONS", "off") in ~w(on true 1)

  @doc "Per-NPC Jev reaction timeout (ms); on timeout the turn goes on without that reaction."
  def npc_reactions_timeout_ms, do: env_int("NPC_REACTIONS_TIMEOUT_MS", 2_500)

  @doc "World agents prototype (persons/locations hold facts for the GM): WORLD_AGENTS=on. Default off."
  def world_agents?, do: System.get_env("WORLD_AGENTS", "off") in ~w(on true 1)

  def ollama_api_base, do: System.get_env("OLLAMA_API_BASE", "http://localhost:11434")
  def log_level, do: System.get_env("LOG_LEVEL", "info")

  defp auto_provider do
    cond do
      present?(xai_api_key()) -> "xai"
      present?(openai_api_key()) -> "openai"
      present?(anthropic_api_key()) -> "anthropic"
      true -> "mock"
    end
  end

  defp env_int(key, default) do
    case System.get_env(key) do
      nil -> default
      value -> String.to_integer(value)
    end
  rescue
    ArgumentError -> default
  end

  defp env_float(key, default) do
    case System.get_env(key) do
      nil -> default
      value -> String.to_float(value)
    end
  rescue
    ArgumentError -> default
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp present?(value), do: String.trim(value) != ""
end
