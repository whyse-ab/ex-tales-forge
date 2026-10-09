defmodule TalesForge.Costs.PlaytestRuns do
  @moduledoc """
  AI spend of playtest runs: what the playtest app's costs page shows, and what
  production's costs page reads live from playtest's `GET /internal/costs`
  (`TalesForgeWeb.CostsPeerController`) for its Playtest section.

  A call belongs to a playtest run when its `game_session_id` is the session of a
  `playtest_runs` row (the persona bot's session; the Jev scorer records on the
  same session). Those calls are split into lines:

  - game: `gm` (the GM, purpose `gm`), `jev_intent` (TypeSafe Jev intent reads,
    purpose `intent` or `intent_shadow`, call type `jev`) and `other_game`
    (scene, NPC reactions, fact extraction, the LLM intent call, ...);
  - bots, never added to game cost: `persona` (the persona bot) and
    `jev_scoring` (the Jev scorer, purpose `scorer`).

  Every other AI call on the app (manual play, calls without a session) is one
  separate `outside_runs` figure, never part of the runs' total. Function rows
  (free Elixir turn steps) are not calls and are left out.

  Money is integer micro-USD. `summary/1` returns string keys so the map is the
  same locally and after the JSON round trip; `normalize/1` validates what
  production receives and recomputes every derived figure from the lines.
  """

  import Ecto.Query

  alias TalesForge.AICalls
  alias TalesForge.Costs
  alias TalesForge.Repo
  alias TalesForge.Schemas.AICall
  alias TalesForge.Schemas.PlaytestRun

  @game_lines ~w(gm jev_intent other_game)
  @bot_lines ~w(persona jev_scoring)
  @lines @game_lines ++ @bot_lines
  @jev_intent_purposes ~w(intent intent_shadow)
  @count_keys ~w(calls cost_micro_usd capped errors)

  @typedoc "Calls, cost (micro-USD) and capped/error counts, string keys."
  @type counts :: %{String.t() => non_neg_integer()}

  @typedoc "One time window (today or this month) of the summary."
  @type window :: %{String.t() => term()}

  @typedoc "The summary served by playtest's `GET /internal/costs` (string keys)."
  @type summary :: %{String.t() => term()}

  @doc "Run lines in display order: the game's, then the bots'."
  @spec lines() :: [String.t()]
  def lines, do: @lines

  @doc "Lines that are game cost (`gm`, `jev_intent`, `other_game`)."
  @spec game_lines() :: [String.t()]
  def game_lines, do: @game_lines

  @doc "Lines that are playtest bot cost (`persona`, `jev_scoring`), never game cost."
  @spec bot_lines() :: [String.t()]
  def bot_lines, do: @bot_lines

  @doc """
  The line of a playtest-run call from its purpose and call type.

      iex> TalesForge.Costs.PlaytestRuns.line("persona", "llm")
      "persona"
      iex> TalesForge.Costs.PlaytestRuns.line("scorer", "jev")
      "jev_scoring"
      iex> TalesForge.Costs.PlaytestRuns.line("intent_shadow", "jev")
      "jev_intent"
      iex> TalesForge.Costs.PlaytestRuns.line("intent", "llm")
      "other_game"
  """
  @spec line(String.t(), String.t()) :: String.t()
  def line("persona", _call_type), do: "persona"
  def line("scorer", _call_type), do: "jev_scoring"
  def line("gm", _call_type), do: "gm"
  def line(purpose, "jev") when purpose in @jev_intent_purposes, do: "jev_intent"
  def line(_purpose, _call_type), do: "other_game"

  @doc """
  Spend in `[from, to]` (UTC): `{lines, outside_runs}`, where `lines` has every
  run line (zeroed when it had no calls) and `outside_runs` sums every call not
  tied to a playtest run. Calls with unknown cost count as 0.
  """
  @spec spend(DateTime.t(), DateTime.t()) :: {%{String.t() => counts()}, counts()}
  def spend(%DateTime{} = from, %DateTime{} = to) do
    {from, to} = {DateTime.truncate(from, :second), DateTime.truncate(to, :second)}
    run_sessions = from(r in PlaytestRun, distinct: true, select: %{sid: r.game_session_id})

    rows =
      from(c in AICall,
        left_join: r in subquery(run_sessions),
        on: r.sid == c.game_session_id,
        where: c.inserted_at >= ^from and c.inserted_at <= ^to,
        where: c.call_type != "function",
        group_by: [c.purpose, c.call_type, is_nil(r.sid)],
        select: %{
          purpose: c.purpose,
          call_type: c.call_type,
          outside: is_nil(r.sid),
          calls: count(c.id),
          cost_micro_usd: type(coalesce(sum(c.cost_micro_usd), 0), :integer),
          capped: filter(count(c.id), c.status == "capped"),
          errors: filter(count(c.id), c.status == "error")
        }
      )
      |> Repo.all()

    empty = Map.new(@lines, &{&1, zero()})

    Enum.reduce(rows, {empty, zero()}, fn row, {lines, outside} ->
      counts = %{
        "calls" => row.calls,
        "cost_micro_usd" => row.cost_micro_usd,
        "capped" => row.capped,
        "errors" => row.errors
      }

      if row.outside,
        do: {lines, add(outside, counts)},
        else: {Map.update!(lines, line(row.purpose, row.call_type), &add(&1, counts)), outside}
    end)
  end

  @doc "Number of playtest runs started in `[from, to]` (UTC)."
  @spec run_count(DateTime.t(), DateTime.t()) :: non_neg_integer()
  def run_count(%DateTime{} = from, %DateTime{} = to) do
    {from, to} = {DateTime.truncate(from, :second), DateTime.truncate(to, :second)}

    PlaytestRun
    |> where([r], r.started_at >= ^from and r.started_at <= ^to)
    |> select([r], count(r.id))
    |> Repo.one()
  end

  @doc """
  This app's playtest-run spend at `now`: today (since midnight
  Europe/Stockholm) and this Stockholm calendar month, per line, with the game
  and bot subtotals, the runs' total, the month's run count and the
  `outside_runs` figure apart. Aggregates only: no rows, prompts or player data.
  """
  @spec summary(DateTime.t()) :: summary()
  def summary(now \\ DateTime.utc_now()) do
    day_from = AICalls.day_start(now)
    month_from = AICalls.month_start(now)
    date = AICalls.local_date(now)
    {today_lines, today_outside} = spend(day_from, now)
    {month_lines, month_outside} = spend(month_from, now)

    %{
      "app" => Costs.app_name(),
      "generated_at" => DateTime.to_iso8601(DateTime.truncate(now, :second)),
      "date" => Date.to_iso8601(date),
      "day_of_month" => date.day,
      "days_in_month" => Date.days_in_month(date),
      "today" => window(DateTime.to_iso8601(day_from), today_lines, today_outside),
      "month" =>
        month_from
        |> DateTime.to_iso8601()
        |> window(month_lines, month_outside)
        |> Map.put("runs", run_count(month_from, now))
    }
  end

  @doc """
  Validates a summary received from playtest and keeps only the known keys;
  every total is recomputed from the lines. Returns `{:ok, summary}` or `:error`.
  """
  @spec normalize(term()) :: {:ok, summary()} | :error
  def normalize(%{"today" => %{} = today, "month" => %{} = month} = body) do
    with {:ok, today_lines, today_outside} <- normalize_window(today),
         {:ok, month_lines, month_outside} <- normalize_window(month),
         day when is_integer(day) and day > 0 <- body["day_of_month"],
         days when is_integer(days) and days >= day <- body["days_in_month"] do
      {:ok,
       %{
         "app" => string_or(body["app"], "playtest"),
         "generated_at" => string_or(body["generated_at"], nil),
         "date" => string_or(body["date"], nil),
         "day_of_month" => day,
         "days_in_month" => days,
         "today" => window(string_or(today["since"], nil), today_lines, today_outside),
         "month" =>
           month["since"]
           |> string_or(nil)
           |> window(month_lines, month_outside)
           |> Map.put("runs", non_neg_or(month["runs"], 0))
       }}
    else
      _ -> :error
    end
  end

  def normalize(_body), do: :error

  @doc "All calls of the playtest app this month: the runs' total plus `outside_runs`."
  @spec month_all_micro_usd(summary()) :: non_neg_integer()
  def month_all_micro_usd(%{"month" => month}),
    do: month["runs_total_micro_usd"] + month["outside_runs"]["cost_micro_usd"]

  # A window with its derived totals, computed from the lines in one place.
  defp window(since, lines, outside) do
    game = sum_cost(lines, @game_lines)
    bots = sum_cost(lines, @bot_lines)

    %{
      "since" => since,
      "lines" => lines,
      "outside_runs" => outside,
      "game_micro_usd" => game,
      "bots_micro_usd" => bots,
      "runs_total_micro_usd" => game + bots
    }
  end

  defp normalize_window(%{"lines" => %{} = lines, "outside_runs" => outside}) do
    normalized = Map.new(@lines, &{&1, normalize_counts(lines[&1])})

    with false <- Enum.any?(Map.values(normalized), &(&1 == :error)),
         %{} = outside <- normalize_counts(outside) do
      {:ok, normalized, outside}
    else
      _ -> :error
    end
  end

  defp normalize_window(_window), do: :error

  defp normalize_counts(%{} = counts) do
    if Enum.all?(@count_keys, &(is_integer(counts[&1]) and counts[&1] >= 0)),
      do: Map.take(counts, @count_keys),
      else: :error
  end

  defp normalize_counts(_counts), do: :error

  defp sum_cost(lines, names), do: names |> Enum.map(&lines[&1]["cost_micro_usd"]) |> Enum.sum()

  defp zero, do: Map.new(@count_keys, &{&1, 0})

  defp add(a, b), do: Map.new(@count_keys, &{&1, a[&1] + b[&1]})

  defp non_neg_or(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_neg_or(_value, default), do: default

  defp string_or(value, _default) when is_binary(value), do: value
  defp string_or(_value, default), do: default
end
