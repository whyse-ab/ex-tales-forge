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
  How the GM turn replies: `"schema"` (default; strict `narration` json_schema
  with bookkeeping fields) or `"prose"` (narrative only, streamed; NPC reactions
  from Jev and notes/summary from a periodic off-path call). Prototype flag:
  anything but `GM_REPLY_MODE=prose` means schema.
  """
  def gm_reply_mode do
    case System.get_env("GM_REPLY_MODE") do
      "prose" -> "prose"
      _ -> "schema"
    end
  end

  def prose_mode?, do: gm_reply_mode() == "prose"

  @doc "Prose mode: stream the GM reply (default true; GM_PROSE_STREAM=false to disable)."
  def gm_prose_stream?, do: System.get_env("GM_PROSE_STREAM") != "false"

  @doc "Prose mode: write GM notes + running summary every N turns (default 3)."
  def gm_notes_every, do: max(env_int("GM_NOTES_EVERY", 3), 1)

  @doc "Prose mode: model for the notes/summary call. Defaults to the tier-2 model."
  def gm_notes_model, do: blank_to_nil(System.get_env("GM_NOTES_MODEL"))

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

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
