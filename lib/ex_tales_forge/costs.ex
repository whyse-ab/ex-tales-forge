defmodule TalesForge.Costs do
  @moduledoc """
  Numbers for the admin costs page (`/admin/operate/costs`). Scope: AI calls only
  (xAI/Grok, TypeSafe Jev); hosting is not in the totals yet.

  - **Playtest app:** only playtest-run spend (`TalesForge.Costs.PlaytestRuns`):
    the GM, Jev intent and other game calls, and apart from them the persona bot
    and Jev scoring. Other calls on playtest (manual play) are one separate line.
  - **Production (and local):** all AI spend. Its own calls (`ai_summary/1`,
    buckets from `TalesForge.AICalls`), plus a Playtest section read live from
    playtest's `GET /internal/costs` by `TalesForge.Costs.Peer` (nothing is
    copied; each thing lives in one place), and one grand total on top
    (`report/3`).
  - Fixed monthly costs, the USD->SEK rate and the playtest warning threshold
    live in one config block: `config :ex_tales_forge, TalesForge.Costs` in
    `config/config.exs`. Each fixed item's `amount` is `{:usd_per_month, n}`,
    `{:sek_per_year, n}` (converted with the configured rate, monthly share =
    yearly / 12) or `:unknown`.

  Money is integer micro-USD throughout; SEK yearly items are converted at the
  configured USD->SEK rate before the monthly share is taken.
  """

  alias TalesForge.AICalls

  alias TalesForge.Costs.PlaytestRuns

  @micro 1_000_000

  # ---------------------------------------------------------------------------
  # AI spend (this app)

  @doc """
  This app's aggregated AI spend at `now`: today (since midnight
  Europe/Stockholm), this Stockholm calendar month, the average game cost per
  game session this month and a month-end projection. String keys, so the map
  is identical locally and after a JSON round trip. Aggregates only: no rows,
  prompts or player data.
  """
  @spec ai_summary(DateTime.t()) :: map()
  def ai_summary(now \\ DateTime.utc_now()) do
    day_from = AICalls.day_start(now)
    month_from = AICalls.month_start(now)
    date = AICalls.local_date(now)

    month_buckets = stringify(AICalls.spend_by_bucket(month_from, now))
    month_total = bucket_total(month_buckets)
    game_cost = month_buckets["game"]["cost_micro_usd"]
    sessions = AICalls.game_session_count(month_from, now)

    %{
      "app" => app_name(),
      "generated_at" => DateTime.to_iso8601(DateTime.truncate(now, :second)),
      "date" => Date.to_iso8601(date),
      "day_of_month" => date.day,
      "days_in_month" => Date.days_in_month(date),
      "today" => %{
        "since" => DateTime.to_iso8601(day_from),
        "buckets" => stringify(AICalls.spend_by_bucket(day_from, now))
      },
      "month" => %{
        "since" => DateTime.to_iso8601(month_from),
        "buckets" => month_buckets,
        "total_micro_usd" => month_total,
        "game_sessions" => sessions,
        "avg_game_micro_usd_per_session" => if(sessions > 0, do: div(game_cost, sessions)),
        "projected_micro_usd" => project(month_total, date.day, Date.days_in_month(date))
      }
    }
  end

  @doc "Month-end projection: spend so far / days elapsed * days in the month."
  @spec project(number(), pos_integer(), pos_integer()) :: integer()
  def project(spent_micro_usd, day_of_month, days_in_month) when day_of_month > 0 do
    round(spent_micro_usd / day_of_month * days_in_month)
  end

  @doc "Sum of `cost_micro_usd` over a summary's buckets (string keys)."
  @spec bucket_total(map()) :: non_neg_integer()
  def bucket_total(buckets) do
    buckets |> Map.values() |> Enum.map(& &1["cost_micro_usd"]) |> Enum.sum()
  end

  defp stringify(buckets) do
    Map.new(buckets, fn {name, counts} ->
      {name, Map.new(counts, fn {k, v} -> {Atom.to_string(k), v} end)}
    end)
  end

  # ---------------------------------------------------------------------------
  # Environments

  # The app name lives in TalesForge.AppRole (shared), so AppRole never
  # depends on this admin module (`mix deploy.check_boundaries`).

  @doc "This app's name (Fly's FLY_APP_NAME), or \"local\" off Fly (`TalesForge.AppRole.app_name/0`)."
  @spec app_name() :: String.t()
  defdelegate app_name, to: TalesForge.AppRole

  @doc "True for the playtest app (`TalesForge.AppRole.playtest?/1`)."
  @spec playtest?(term()) :: boolean()
  defdelegate playtest?(app), to: TalesForge.AppRole

  @doc "Display name of an environment from its app name."
  @spec env_label(String.t()) :: String.t()
  def env_label(app) do
    cond do
      playtest?(app) -> "Playtest (#{app})"
      app == "local" -> "This app (local)"
      true -> "Production (#{app})"
    end
  end

  # ---------------------------------------------------------------------------
  # Fixed costs, currency, threshold

  defp config, do: Application.get_env(:ex_tales_forge, __MODULE__, [])

  @doc """
  Fixed costs from config: maps with `name`, `env`, `amount` and `source`.
  `amount` is `{:usd_per_month, n}`, `{:sek_per_year, n}` or `:unknown`.
  """
  @spec fixed_costs() :: [map()]
  def fixed_costs, do: Keyword.get(config(), :fixed_monthly, [])

  @doc "USD->SEK rate from config: %{rate: float, as_of: Date, source: string}."
  @spec usd_sek() :: %{rate: number(), as_of: Date.t(), source: String.t()}
  def usd_sek, do: Keyword.fetch!(config(), :usd_sek)

  @doc "Playtest warning threshold in USD per month."
  @spec playtest_warn_usd() :: number()
  def playtest_warn_usd, do: Keyword.get(config(), :playtest_warn_usd, 15.0)

  @doc """
  A fixed cost's monthly share as micro-USD, or `:unknown`.

  `{:usd_per_month, n}` is `n` dollars. `{:sek_per_year, n}` is converted with
  the configured USD->SEK rate, then divided by 12.
  """
  @spec fixed_micro_usd(map(), number()) :: integer() | :unknown
  def fixed_micro_usd(item, rate \\ usd_sek().rate)
  def fixed_micro_usd(%{amount: :unknown}, _rate), do: :unknown

  def fixed_micro_usd(%{amount: {:usd_per_month, usd}}, _rate) when is_number(usd),
    do: round(usd * @micro)

  def fixed_micro_usd(%{amount: {:sek_per_year, sek}}, rate)
      when is_number(sek) and is_number(rate) and rate > 0,
      do: round(sek / rate / 12 * @micro)

  @doc "True when the item is billed in SEK per year (show yearly + monthly share)."
  @spec sek_per_year?(map()) :: boolean()
  def sek_per_year?(%{amount: {:sek_per_year, _}}), do: true
  def sek_per_year?(_item), do: false

  @doc "The SEK/year figure for a `{:sek_per_year, n}` item, or nil."
  @spec sek_per_year(map()) :: number() | nil
  def sek_per_year(%{amount: {:sek_per_year, sek}}) when is_number(sek), do: sek
  def sek_per_year(_item), do: nil

  @doc "Micro-USD to SEK at the configured rate (float)."
  @spec to_sek(integer(), number()) :: float()
  def to_sek(micro_usd, rate \\ usd_sek().rate), do: micro_usd / @micro * rate

  # ---------------------------------------------------------------------------
  # Page report (production)

  @doc """
  The top of production's page: one grand total of AI spend this month across
  both apps (production's own calls, playtest's run calls and playtest's other
  calls, each its own line) plus a month-end projection, the fixed costs (shown
  apart, not in the grand total: the scope is AI calls for now) and the playtest
  threshold check.

  `playtest` is `{:ok, summary}` (a `TalesForge.Costs.PlaytestRuns` summary),
  `{:error, :not_configured}`, `{:error, :loading}` or `{:error, reason}`. Without
  playtest numbers the grand total is production's alone and
  `playtest_included` is false. Unknown fixed costs are listed in `:unknown`.
  """
  @spec report(map(), {:ok, PlaytestRuns.summary()} | {:error, term()}, [map()]) :: map()
  def report(production, playtest, fixed \\ fixed_costs()) do
    known = Enum.reject(fixed, &(fixed_micro_usd(&1) == :unknown))
    prod_month = production["month"]["total_micro_usd"]
    prod_projected = production["month"]["projected_micro_usd"]
    pt = playtest_parts(playtest)

    %{
      production_month_micro_usd: prod_month,
      production_projected_micro_usd: prod_projected,
      playtest_included: pt != nil,
      playtest_runs_month_micro_usd: pt && pt.runs,
      playtest_game_month_micro_usd: pt && pt.game,
      playtest_bots_month_micro_usd: pt && pt.bots,
      playtest_outside_month_micro_usd: pt && pt.outside,
      playtest_projected_micro_usd: pt && pt.projected,
      grand_month_micro_usd: prod_month + ((pt && pt.runs + pt.outside) || 0),
      grand_projected_micro_usd: prod_projected + ((pt && pt.projected) || 0),
      fixed: fixed,
      fixed_known_micro_usd: known |> Enum.map(&fixed_micro_usd/1) |> Enum.sum(),
      unknown: fixed |> Enum.filter(&(fixed_micro_usd(&1) == :unknown)) |> Enum.map(& &1.name),
      playtest: playtest_check(pt, known)
    }
  end

  defp playtest_parts({:ok, %{"month" => month} = summary}) do
    all = PlaytestRuns.month_all_micro_usd(summary)

    %{
      runs: month["runs_total_micro_usd"],
      game: month["game_micro_usd"],
      bots: month["bots_micro_usd"],
      outside: month["outside_runs"]["cost_micro_usd"],
      projected: project(all, summary["day_of_month"], summary["days_in_month"])
    }
  end

  defp playtest_parts(_playtest), do: nil

  # Playtest fixed costs (known items tagged :playtest) plus playtest's projected
  # AI spend (runs and other calls), against the threshold. :unavailable when
  # playtest's numbers aren't on the page.
  defp playtest_check(nil, _known_fixed),
    do: %{status: :unavailable, threshold_micro_usd: threshold()}

  defp playtest_check(pt, known_fixed) do
    fixed =
      known_fixed
      |> Enum.filter(&(&1.env == :playtest))
      |> Enum.map(&fixed_micro_usd/1)
      |> Enum.sum()

    total = fixed + pt.projected

    %{
      status: if(total > threshold(), do: :over, else: :ok),
      fixed_micro_usd: fixed,
      projected_ai_micro_usd: pt.projected,
      total_micro_usd: total,
      threshold_micro_usd: threshold()
    }
  end

  defp threshold, do: round(playtest_warn_usd() * @micro)
end
