defmodule TalesForge.AICalls do
  @moduledoc """
  Records the cost of every LLM call and sums it per session or since a point in time.

  Costs are integer micro-USD. The provider-billed cost (`usage.cost_in_usd_ticks`,
  1 USD = 10^10 ticks) wins when present; otherwise it is computed from the
  `:llm_prices` table in config. Recording never raises: gameplay must not depend on it.

  Spending caps (`:ai_spend_caps`, set from `AI_CAP_SESSION_USD` / `AI_CAP_DAY_USD`)
  are checked before each request. The day starts at midnight Europe/Stockholm.

  Every row has a `call_type` (`llm`, `jev` or `function`, see docs/call-types.md)
  and the session's world/module and game-system tags (`TalesForge.AICalls.Tags`).
  Function rows (timed Elixir turn steps, `TalesForge.AICalls.Steps`) cost 0 and
  are left out of call counts; cost sums are unaffected by them.
  """

  require Logger

  import Ecto.Query

  alias TalesForge.AICalls.Tags
  alias TalesForge.Repo
  alias TalesForge.Schemas.AICall

  @ticks_per_micro_usd 10_000
  @day_zone "Europe/Stockholm"
  # Playtest bot calls: outside the session cap and the game's cost figures.
  @bot_purposes ~w(persona scorer)
  @default_persona_run_micro_usd 500_000

  @doc """
  Inserts one ai_calls row. Always returns :ok; failures are logged.

  Without an explicit `call_type` it follows the model: `jev-*` is `"jev"`,
  `"elixir"` is `"function"`, anything else `"llm"`. Without explicit
  `adventure_id` / `game_system`, the tags are read from the row's session.
  """
  def record(attrs) do
    usage = Map.get(attrs, :usage, %{})
    attrs = attrs |> Map.put_new(:call_type, call_type(attrs[:model])) |> put_tags()

    {cost, source} =
      if attrs.call_type == "function", do: {0, "free"}, else: cost(attrs.model, usage)

    attrs
    |> Map.merge(
      Map.take(usage, [:input_tokens, :output_tokens, :cached_tokens, :reasoning_tokens])
    )
    |> Map.merge(%{cost_micro_usd: cost, cost_source: source})
    |> then(&AICall.changeset(%AICall{}, &1))
    |> Repo.insert_isolated()
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

  @doc "Call type implied by a model name (see `record/1`)."
  def call_type("jev-" <> _version), do: "jev"
  def call_type("elixir"), do: "function"
  def call_type(_model), do: "llm"

  defp put_tags(%{adventure_id: _, game_system: _} = attrs), do: attrs

  defp put_tags(attrs),
    do: Map.merge(Tags.for_session(attrs[:game_session_id]), attrs)

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

  def bot_purposes, do: @bot_purposes

  @doc """
  Spend buckets, in display order: "game" (gm, intent, scene and any other game
  call) and one bucket per playtest bot purpose ("persona", "scorer").
  """
  def buckets, do: ["game" | @bot_purposes]

  @doc "The spend bucket of a call purpose: a bot purpose is its own bucket, the rest is \"game\"."
  def bucket(purpose) when purpose in @bot_purposes, do: purpose
  def bucket(_game_purpose), do: "game"

  @doc """
  Calls, micro-USD cost and capped/error counts per bucket for calls inserted in
  `[from, to]` (UTC). Every bucket is present, zeroed when it had no calls.
  Calls with unknown cost count as 0. Function rows (free Elixir steps) are not calls.
  """
  def spend_by_bucket(%DateTime{} = from, %DateTime{} = to) do
    {from, to} = {DateTime.truncate(from, :second), DateTime.truncate(to, :second)}

    rows =
      AICall
      |> where([c], c.inserted_at >= ^from and c.inserted_at <= ^to)
      |> where([c], c.call_type != "function")
      |> group_by([c], c.purpose)
      |> select([c], %{
        purpose: c.purpose,
        calls: count(c.id),
        cost_micro_usd: type(coalesce(sum(c.cost_micro_usd), 0), :integer),
        capped: filter(count(c.id), c.status == "capped"),
        errors: filter(count(c.id), c.status == "error")
      })
      |> Repo.all()

    empty = Map.new(buckets(), &{&1, %{calls: 0, cost_micro_usd: 0, capped: 0, errors: 0}})

    Enum.reduce(rows, empty, fn row, acc ->
      Map.update!(acc, bucket(row.purpose), fn totals ->
        %{
          calls: totals.calls + row.calls,
          cost_micro_usd: totals.cost_micro_usd + row.cost_micro_usd,
          capped: totals.capped + row.capped,
          errors: totals.errors + row.errors
        }
      end)
    end)
  end

  @doc "Number of game sessions with at least one game-bucket call in `[from, to]` (UTC)."
  def game_session_count(%DateTime{} = from, %DateTime{} = to) do
    {from, to} = {DateTime.truncate(from, :second), DateTime.truncate(to, :second)}

    AICall
    |> where([c], c.inserted_at >= ^from and c.inserted_at <= ^to)
    |> where([c], c.purpose not in ^@bot_purposes and not is_nil(c.game_session_id))
    |> where([c], c.call_type != "function")
    |> select([c], count(c.game_session_id, :distinct))
    |> Repo.one()
  end

  @doc """
  Micro-USD the game spent in a session (gm, intent, scene). Playtest bot calls
  (persona, scorer) are left out. Calls with unknown cost count as 0.
  """
  def total_cost_for_session(session_id) do
    AICall
    |> where([c], c.game_session_id == ^session_id and c.purpose not in ^@bot_purposes)
    |> sum_cost()
  end

  @doc "Micro-USD spent across all sessions since `since` (UTC), bot calls included."
  def total_cost_since(%DateTime{} = since) do
    AICall
    |> where([c], c.inserted_at >= ^since)
    |> sum_cost()
  end

  @doc "Totals of a session's persona bot calls: count, latency, tokens and cost."
  def persona_totals(session_id) do
    AICall
    |> where([c], c.game_session_id == ^session_id and c.purpose == "persona")
    |> select([c], %{
      calls: count(c.id),
      latency_ms: type(coalesce(sum(c.latency_ms), 0), :integer),
      input_tokens: type(coalesce(sum(c.input_tokens), 0), :integer),
      output_tokens: type(coalesce(sum(c.output_tokens), 0), :integer),
      cost_micro_usd: type(coalesce(sum(c.cost_micro_usd), 0), :integer)
    })
    |> Repo.one()
  end

  @doc """
  `:ok`, or `{:error, {:session | :persona_run | :day, limit, spent}}` (micro-USD)
  when spend has reached a cap for a call with this `purpose`:

  - session: game calls only, against the game's spend in that session;
  - persona_run: persona calls, against that session's persona spend (one
    playtest run per session), default #{@default_persona_run_micro_usd} when unset;
  - day: every call, bot calls included.

  Calls without a session only face the day cap.
  """
  def check_spend_caps(session_id, purpose \\ "gm", now \\ DateTime.utc_now()) do
    caps = Application.get_env(:ex_tales_forge, :ai_spend_caps, [])
    session_cap = if purpose not in @bot_purposes, do: caps[:session_micro_usd]

    persona_cap =
      if purpose == "persona",
        do: caps[:persona_run_micro_usd] || @default_persona_run_micro_usd

    with :ok <- check_cap(:session, session_cap, session_id, now),
         :ok <- check_cap(:persona_run, persona_cap, session_id, now) do
      check_cap(:day, caps[:day_micro_usd], session_id, now)
    end
  end

  @doc "UTC instant of the latest midnight in Europe/Stockholm at `now`."
  def day_start(%DateTime{} = now), do: local_midnight(local_date(now))

  @doc "Start of the Europe/Stockholm calendar month containing `now`, as UTC."
  def month_start(%DateTime{} = now), do: local_midnight(Date.beginning_of_month(local_date(now)))

  @doc "The Europe/Stockholm calendar date of `now` (the day used by the day cap)."
  def local_date(%DateTime{} = now) do
    now |> DateTime.shift_zone!(@day_zone, TimeZoneInfo.TimeZoneDatabase) |> DateTime.to_date()
  end

  defp local_midnight(%Date{} = date) do
    db = TimeZoneInfo.TimeZoneDatabase
    {:ok, midnight} = DateTime.new(date, ~T[00:00:00], @day_zone, db)
    DateTime.shift_zone!(midnight, "Etc/UTC")
  end

  defp check_cap(_kind, nil, _session_id, _now), do: :ok
  defp check_cap(kind, _limit, nil, _now) when kind != :day, do: :ok

  defp check_cap(kind, limit, session_id, now) do
    spent =
      case kind do
        :session -> total_cost_for_session(session_id)
        :persona_run -> persona_totals(session_id).cost_micro_usd
        :day -> total_cost_since(day_start(now))
      end

    if spent >= limit, do: {:error, {kind, limit, spent}}, else: :ok
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
