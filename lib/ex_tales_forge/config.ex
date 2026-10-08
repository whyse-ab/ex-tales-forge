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

  @doc """
  Every default-variant turn goes through the Tier 1 intent call, even when the
  heuristic is confident, so every turn has the intent call's input safety read
  (`TalesForge.Game.PlayerQuote`): INTENT_CALL_EVERY_TURN=on. Default off.
  """
  def intent_call_every_turn?,
    do: System.get_env("INTENT_CALL_EVERY_TURN", "off") in ~w(on true 1)

  @doc "NPC reaction prototype (Jev, before the GM call): NPC_REACTIONS=on. Default off."
  def npc_reactions?, do: System.get_env("NPC_REACTIONS", "off") in ~w(on true 1)

  @doc "Per-NPC Jev reaction timeout (ms); on timeout the turn goes on without that reaction."
  def npc_reactions_timeout_ms, do: env_int("NPC_REACTIONS_TIMEOUT_MS", 2_500)

  @doc "World agents prototype (persons/locations hold facts for the GM): WORLD_AGENTS=on. Default off."
  def world_agents?, do: System.get_env("WORLD_AGENTS", "off") in ~w(on true 1)

  @doc """
  The places and people around the Valley Inn (`TalesForge.Game.Features`,
  feature `inn_world`): INN_WORLD=on. Read when a session is created. Default off.
  """
  def inn_world?, do: System.get_env("INN_WORLD", "off") in ~w(on true 1)

  @doc """
  The Tinjacks antagonist (feature `antagonist`, needs INN_WORLD):
  WORLD_ANTAGONIST=on. Read when a session is created. Default off.
  """
  def world_antagonist?, do: System.get_env("WORLD_ANTAGONIST", "off") in ~w(on true 1)

  @doc """
  Behaviour variant of new sessions (`TalesForge.Game.Variant`): GAME_VARIANT,
  `default` unless set. `baseline` plays the game as before the 2026-10-07 rework.
  """
  def game_variant, do: System.get_env("GAME_VARIANT", "default") |> String.trim()

  def ollama_api_base, do: System.get_env("OLLAMA_API_BASE", "http://localhost:11434")

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
