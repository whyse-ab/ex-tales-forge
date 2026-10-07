defmodule Mix.Tasks.Dev.Check do
  @moduledoc """
  Verifies local development setup: .env file, PostgreSQL, and LLM configuration.

      mix dev.check
  """
  use Mix.Task

  @shortdoc "Verify local dev environment (Postgres, API keys, LLM provider)"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    check_dotenv()
    check_database()
    check_llm()

    :ok
  end

  defp check_dotenv do
    env_path = Path.expand(".env")

    if File.exists?(env_path) do
      Mix.shell().info("[ok] .env found at #{env_path}")
    else
      Mix.shell().error("[missing] .env — copy the template: cp .env.example .env")
    end
  end

  defp check_database do
    case TalesForge.Repo.query("SELECT 1") do
      {:ok, _} ->
        Mix.shell().info("[ok] PostgreSQL connected")

      {:error, reason} ->
        Mix.shell().error(
          "[error] PostgreSQL — #{Exception.message(reason)}\n" <>
            "        Start Postgres (e.g. brew services start postgresql@16) and run mix setup"
        )
    end
  end

  defp check_llm do
    provider = TalesForge.Config.llm_provider()
    key = TalesForge.Config.xai_api_key()

    if key_present?(key) do
      Mix.shell().info("[ok] XAI_API_KEY set (#{mask(key)})")
    else
      Mix.shell().error(
        "[missing] XAI_API_KEY — GM will use mock narration until you add a key to .env"
      )
    end

    Mix.shell().info("      LLM provider: #{provider}")
    Mix.shell().info("      Tier 1 model: #{TalesForge.LLM.tier1_model()}")
    Mix.shell().info("      Tier 2 model: #{TalesForge.LLM.tier2_model()}")

    model = TalesForge.LLM.effective_xai_model()

    if key_present?(key) and TalesForge.LLM.reasoning_model?(model) do
      Mix.shell().error(
        "[warning] XAI_MODEL looks like a reasoning model — use grok-4.20-0309-non-reasoning for fast turns"
      )
    end
  end

  defp key_present?(value), do: String.trim(value) != ""

  defp mask(key) when byte_size(key) <= 8, do: "****"

  defp mask(key) do
    prefix = String.slice(key, 0, 4)
    suffix = String.slice(key, -4..-1//1)
    "#{prefix}...#{suffix}"
  end
end
