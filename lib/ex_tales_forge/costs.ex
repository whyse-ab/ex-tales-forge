defmodule TalesForge.Costs do
  @moduledoc """
  Numbers for the admin costs page (`/admin/costs`).

  - AI spend comes from `ai_calls` through `TalesForge.AICalls` (buckets, the
    Europe/Stockholm day and month). `ai_summary/1` is this app's aggregate; the
    same shape is served to the peer app by `GET /internal/costs` and fetched
    from it by `TalesForge.Costs.Peer`.
  - Fixed monthly costs, the USD->SEK rate and the playtest warning threshold
    live in one config block: `config :ex_tales_forge, TalesForge.Costs` in
    `config/config.exs`. Each fixed item's `amount` is `{:usd_per_month, n}`,
    `{:sek_per_year, n}` (converted with the configured rate, monthly share =
    yearly / 12) or `:unknown`.

  Money is integer micro-USD throughout; SEK yearly items are converted at the
  configured USD->SEK rate before the monthly share is taken.
  """

  alias TalesForge.AICalls

  @micro 1_000_000
  @count_keys ~w(calls cost_micro_usd capped errors)

  # ---------------------------------------------------------------------------
  # AI spend (this app)

  @doc """
  This app's aggregated AI spend at `now`: today (since midnight
  Europe/Stockholm), this Stockholm calendar month, the average game cost per
  game session this month and a month-end projection. String keys, so the map
  is identical locally and after a JSON round trip. Aggregates only: no rows,
  prompts or player data.
  """
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
  def project(spent_micro_usd, day_of_month, days_in_month) when day_of_month > 0 do
    round(spent_micro_usd / day_of_month * days_in_month)
  end

  @doc "Sum of `cost_micro_usd` over a summary's buckets (string keys)."
  def bucket_total(buckets) do
    buckets |> Map.values() |> Enum.map(& &1["cost_micro_usd"]) |> Enum.sum()
  end

  @doc """
  Validates a summary received from the peer and keeps only the known keys.
  Returns `{:ok, summary}` or `:error`.
  """
  def normalize_summary(%{"today" => today, "month" => month} = body) do
    with {:ok, today_buckets} <- normalize_buckets(today),
         {:ok, month_buckets} <- normalize_buckets(month),
         day when is_integer(day) and day > 0 <- body["day_of_month"],
         days when is_integer(days) and days >= day <- body["days_in_month"] do
      month_total = bucket_total(month_buckets)
      sessions = int_or(month["game_sessions"], 0)

      {:ok,
       %{
         "app" => string_or(body["app"], "peer"),
         "generated_at" => string_or(body["generated_at"], nil),
         "date" => string_or(body["date"], nil),
         "day_of_month" => day,
         "days_in_month" => days,
         "today" => %{"since" => string_or(today["since"], nil), "buckets" => today_buckets},
         "month" => %{
           "since" => string_or(month["since"], nil),
           "buckets" => month_buckets,
           "total_micro_usd" => month_total,
           "game_sessions" => sessions,
           "avg_game_micro_usd_per_session" =>
             if(sessions > 0, do: div(month_buckets["game"]["cost_micro_usd"], sessions)),
           "projected_micro_usd" => project(month_total, day, days)
         }
       }}
    else
      _ -> :error
    end
  end

  def normalize_summary(_body), do: :error

  defp normalize_buckets(%{"buckets" => %{} = buckets}) do
    normalized = Map.new(AICalls.buckets(), &{&1, normalize_counts(buckets[&1])})
    if Enum.any?(Map.values(normalized), &(&1 == :error)), do: :error, else: {:ok, normalized}
  end

  defp normalize_buckets(_), do: :error

  defp normalize_counts(%{} = counts) do
    if Enum.all?(@count_keys, &(is_integer(counts[&1]) and counts[&1] >= 0)),
      do: Map.take(counts, @count_keys),
      else: :error
  end

  defp normalize_counts(_), do: :error

  defp stringify(buckets) do
    Map.new(buckets, fn {name, counts} ->
      {name, Map.new(counts, fn {k, v} -> {Atom.to_string(k), v} end)}
    end)
  end

  defp int_or(value, _default) when is_integer(value) and value >= 0, do: value
  defp int_or(_value, default), do: default

  defp string_or(value, _default) when is_binary(value), do: value
  defp string_or(_value, default), do: default

  # ---------------------------------------------------------------------------
  # Environments

  @doc "This app's name (Fly's FLY_APP_NAME), or \"local\" off Fly."
  def app_name do
    case Application.get_env(:ex_tales_forge, :app_name) do
      name when is_binary(name) and name != "" -> name
      _ -> "local"
    end
  end

  @doc "True for the playtest app (its name contains \"playtest\")."
  def playtest?(app) when is_binary(app), do: String.contains?(app, "playtest")
  def playtest?(_app), do: false

  @doc "Display name of an environment from its app name."
  def env_label(app) do
    cond do
      playtest?(app) -> "Playtest (#{app})"
      app == "local" -> "This app (local)"
      true -> "Production (#{app})"
    end
  end

  @doc "What the peer is called on this app's page: playtest from production, and vice versa."
  def peer_label(app \\ app_name()), do: if(playtest?(app), do: "production", else: "playtest")

  # ---------------------------------------------------------------------------
  # Fixed costs, currency, threshold

  defp config, do: Application.get_env(:ex_tales_forge, __MODULE__, [])

  @doc """
  Fixed costs from config: maps with `name`, `env`, `amount` and `source`.
  `amount` is `{:usd_per_month, n}`, `{:sek_per_year, n}` or `:unknown`.
  """
  def fixed_costs, do: Keyword.get(config(), :fixed_monthly, [])

  @doc "USD->SEK rate from config: %{rate: float, as_of: Date, source: string}."
  def usd_sek, do: Keyword.fetch!(config(), :usd_sek)

  @doc "Playtest warning threshold in USD per month."
  def playtest_warn_usd, do: Keyword.get(config(), :playtest_warn_usd, 15.0)

  @doc """
  A fixed cost's monthly share as micro-USD, or `:unknown`.

  `{:usd_per_month, n}` is `n` dollars. `{:sek_per_year, n}` is converted with
  the configured USD->SEK rate, then divided by 12.
  """
  def fixed_micro_usd(item, rate \\ usd_sek().rate)
  def fixed_micro_usd(%{amount: :unknown}, _rate), do: :unknown

  def fixed_micro_usd(%{amount: {:usd_per_month, usd}}, _rate) when is_number(usd),
    do: round(usd * @micro)

  def fixed_micro_usd(%{amount: {:sek_per_year, sek}}, rate)
      when is_number(sek) and is_number(rate) and rate > 0,
      do: round(sek / rate / 12 * @micro)

  @doc "True when the item is billed in SEK per year (show yearly + monthly share)."
  def sek_per_year?(%{amount: {:sek_per_year, _}}), do: true
  def sek_per_year?(_item), do: false

  @doc "The SEK/year figure for a `{:sek_per_year, n}` item, or nil."
  def sek_per_year(%{amount: {:sek_per_year, sek}}) when is_number(sek), do: sek
  def sek_per_year(_item), do: nil

  @doc "Micro-USD to SEK at the configured rate (float)."
  def to_sek(micro_usd, rate \\ usd_sek().rate), do: micro_usd / @micro * rate

  # ---------------------------------------------------------------------------
  # Page report

  @doc """
  Everything the page shows besides the per-environment tables: fixed costs,
  totals for both environments, the AI projection and the playtest check.

  `peer` is `{:ok, summary}`, `{:error, :not_configured}` or `{:error, reason}`.
  Unknown fixed costs are listed in `:unknown` and excluded from every total.
  """
  def report(local, peer, fixed \\ fixed_costs()) do
    summaries = [local | peer_summaries(peer)]
    known = Enum.reject(fixed, &(fixed_micro_usd(&1) == :unknown))
    fixed_known = known |> Enum.map(&fixed_micro_usd/1) |> Enum.sum()
    ai_month = summaries |> Enum.map(& &1["month"]["total_micro_usd"]) |> Enum.sum()
    ai_projected = summaries |> Enum.map(& &1["month"]["projected_micro_usd"]) |> Enum.sum()

    %{
      fixed: fixed,
      fixed_known_micro_usd: fixed_known,
      unknown: fixed |> Enum.filter(&(fixed_micro_usd(&1) == :unknown)) |> Enum.map(& &1.name),
      ai_month_micro_usd: ai_month,
      ai_projected_micro_usd: ai_projected,
      total_so_far_micro_usd: fixed_known + ai_month,
      total_projected_micro_usd: fixed_known + ai_projected,
      peer_included: match?({:ok, _}, peer),
      playtest: playtest_check(summaries, known)
    }
  end

  defp peer_summaries({:ok, summary}), do: [summary]
  defp peer_summaries(_peer), do: []

  # Playtest fixed costs (known items tagged :playtest) plus playtest's projected
  # AI spend, against the threshold. :unavailable when playtest's AI numbers
  # aren't on this page (peer down or not configured).
  defp playtest_check(summaries, known_fixed) do
    threshold = round(playtest_warn_usd() * @micro)

    case Enum.find(summaries, &playtest?(&1["app"])) do
      nil ->
        %{status: :unavailable, threshold_micro_usd: threshold}

      summary ->
        fixed =
          known_fixed
          |> Enum.filter(&(&1.env == :playtest))
          |> Enum.map(&fixed_micro_usd/1)
          |> Enum.sum()

        total = fixed + summary["month"]["projected_micro_usd"]

        %{
          status: if(total > threshold, do: :over, else: :ok),
          fixed_micro_usd: fixed,
          projected_ai_micro_usd: summary["month"]["projected_micro_usd"],
          total_micro_usd: total,
          threshold_micro_usd: threshold
        }
    end
  end
end
