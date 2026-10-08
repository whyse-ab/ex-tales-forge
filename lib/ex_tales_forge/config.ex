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
  The Jev intent mode new default-variant sessions get (`INTENT_JEV`, read in
  `config/runtime.exs`): `:off` (today's intent path), `:shadow` (today's path
  plays; the Jev intent read runs alongside and is only logged) or `:on` (the
  Jev intent read drives the turn). Default `:off`. See `TalesForge.IntentJev`.
  """
  @spec intent_jev_mode() :: :off | :shadow | :on
  def intent_jev_mode, do: Application.get_env(:ex_tales_forge, :intent_jev, :off)

  @doc "Jev intent: the confidence at or above which the turn acts on the top reading (`INTENT_ACT_MIN_CONFIDENCE`, default 0.70)."
  @spec intent_act_min_confidence() :: float()
  def intent_act_min_confidence,
    do: Application.get_env(:ex_tales_forge, :intent_act_min_confidence, 0.70)

  @doc "Jev intent: the confidence below which the turn may ask the player (`INTENT_ASK_BELOW_CONFIDENCE`, default 0.45)."
  @spec intent_ask_below_confidence() :: float()
  def intent_ask_below_confidence,
    do: Application.get_env(:ex_tales_forge, :intent_ask_below_confidence, 0.45)

  @doc "Jev intent: the call's receive timeout in ms on the player's clock (`INTENT_JEV_TIMEOUT_MS`, default 1500)."
  @spec intent_jev_timeout_ms() :: pos_integer()
  def intent_jev_timeout_ms,
    do: Application.get_env(:ex_tales_forge, :intent_jev_timeout_ms, 1_500)

  @doc "The minimum `benign` safety confidence for the GM to get the player's own words (`PLAYER_QUOTE_MIN_BENIGN_CONFIDENCE`, default 0.90)."
  @spec player_quote_min_benign_confidence() :: float()
  def player_quote_min_benign_confidence,
    do: Application.get_env(:ex_tales_forge, :player_quote_min_benign_confidence, 0.90)

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
