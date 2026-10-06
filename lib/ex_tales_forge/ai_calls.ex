defmodule TalesForge.AICalls do
  @moduledoc """
  Records the cost of every LLM call and sums it per session or since a point in time.

  Costs are integer micro-USD. The provider-billed cost (`usage.cost_in_usd_ticks`,
  1 USD = 10^10 ticks) wins when present; otherwise it is computed from the
  `:llm_prices` table in config. Recording never raises: gameplay must not depend on it.
  """

  require Logger

  import Ecto.Query

  alias TalesForge.Repo
  alias TalesForge.Schemas.AICall

  @ticks_per_micro_usd 10_000

  @doc "Inserts one ai_calls row. Always returns :ok; failures are logged."
  def record(attrs) do
    usage = Map.get(attrs, :usage, %{})
    {cost, source} = cost(attrs.model, usage)

    attrs
    |> Map.merge(
      Map.take(usage, [:input_tokens, :output_tokens, :cached_tokens, :reasoning_tokens])
    )
    |> Map.merge(%{cost_micro_usd: cost, cost_source: source})
    |> then(&AICall.changeset(%AICall{}, &1))
    |> Repo.insert(mode: :savepoint)
    |> case do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "ai_call not recorded model=#{attrs.model} errors=#{inspect(changeset.errors)}"
        )
    end
  rescue
    e ->
      Logger.error(
        "ai_call not recorded model=#{inspect(attrs[:model])} error=#{Exception.message(e)}"
      )
  end

  @doc "Token usage from an OpenAI-compatible (xAI) chat completion body."
  def usage(%{"usage" => %{} = usage}) do
    %{
      input_tokens: usage["prompt_tokens"],
      output_tokens: usage["completion_tokens"],
      cached_tokens: get_in(usage, ["prompt_tokens_details", "cached_tokens"]),
      reasoning_tokens: get_in(usage, ["completion_tokens_details", "reasoning_tokens"]),
      cost_ticks: usage["cost_in_usd_ticks"]
    }
  end

  def usage(_body), do: %{}

  def cost(_model, %{cost_ticks: ticks}) when is_integer(ticks) do
    {div(ticks + div(@ticks_per_micro_usd, 2), @ticks_per_micro_usd), "provider"}
  end

  def cost(model, usage) do
    case price_table_cost(model, usage) do
      nil -> {nil, nil}
      cost -> {cost, "price_table"}
    end
  end

  @doc """
  Micro-USD from the config price table (USD per 1M tokens == micro-USD per token).
  Cached tokens are part of input tokens; reasoning tokens are billed as output on
  top of completion tokens. Unknown model or no usage => nil.
  """
  def price_table_cost(model, %{input_tokens: input} = usage) when is_integer(input) do
    case prices(model) do
      nil ->
        Logger.warning("no LLM price for model=#{model}; cost not recorded")
        nil

      prices ->
        cached = Map.get(usage, :cached_tokens) || 0
        output = (Map.get(usage, :output_tokens) || 0) + (Map.get(usage, :reasoning_tokens) || 0)
        rates = rates_for(prices, input)

        round(
          (input - cached) * rates.input + cached * rates.cached_input + output * rates.output
        )
    end
  end

  def price_table_cost(_model, _usage), do: nil

  @doc "Micro-USD spent in a session. Calls with unknown cost count as 0."
  def total_cost_for_session(session_id) do
    AICall
    |> where([c], c.game_session_id == ^session_id)
    |> sum_cost()
  end

  @doc "Micro-USD spent across all sessions since `since` (UTC)."
  def total_cost_since(%DateTime{} = since) do
    AICall
    |> where([c], c.inserted_at >= ^since)
    |> sum_cost()
  end

  defp sum_cost(query) do
    query
    |> select([c], type(coalesce(sum(c.cost_micro_usd), 0), :integer))
    |> Repo.one()
  end

  defp prices(model) do
    name = model |> String.split("/") |> List.last()
    Map.get(Application.get_env(:ex_tales_forge, :llm_prices, %{}), name)
  end

  defp rates_for(%{long_context: %{threshold: threshold} = long}, input) when input >= threshold,
    do: long

  defp rates_for(prices, _input), do: prices
end
