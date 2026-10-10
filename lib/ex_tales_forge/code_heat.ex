defmodule TalesForge.CodeHeat do
  @moduledoc """
  The code heat map: call counts and call time of the app's functions, one
  sample each day.

  `TalesForge.CodeHeat.Sampler` traces the app's modules with BEAM call-time
  tracing (`TalesForge.CodeHeat.Tracer`). Each day it writes one sample of the
  last 24 hours (`TalesForge.Schemas.CodeHeatSnapshot`). The admin page
  `/admin/operate/code-heat` (`TalesForgeWeb.AdminLive.CodeHeatLive`) shows
  the latest sample as a heat map of apps, modules or functions.

  The heat map runs on playtest only. Set `CODE_HEAT_MAP=on` to turn it on
  (`fly.playtest.toml`). `enabled?/1` is always false on production, also
  when the variable is set there.

  Config `config :ex_tales_forge, TalesForge.CodeHeat`:

  - `:enabled`: true from `CODE_HEAT_MAP=on` (`config/runtime.exs`). Default false.
  - `:read_every_ms`: the sampler adds the counters to its totals and starts
    a new session at this interval. This keeps the counter memory small.
    Default 1 hour.
  - `:sample_every_ms`: the sampler writes one sample at this interval.
    Default 24 hours.
  - `:max_modules`: the maximum number of traced modules. Default 1500.
  - `:max_rows`: the maximum number of functions in one sample (the
    functions with the most time). Default 2000.
  - `:keep`: the number of samples to keep. Default 14.

  The page shows no money. AI calls (Jev and LLM) show the number of calls
  and the time only (`ai_calls/1`).
  """

  import Ecto.Query

  alias TalesForge.AppRole
  alias TalesForge.Repo
  alias TalesForge.Schemas.AICall
  alias TalesForge.Schemas.CodeHeatSnapshot

  @app :ex_tales_forge

  @defaults [
    enabled: false,
    read_every_ms: :timer.hours(1),
    sample_every_ms: :timer.hours(24),
    max_modules: 1500,
    max_rows: 2000,
    keep: 14
  ]

  # Modules whose functions make AI calls. The page marks them "AI".
  @ai_modules ~w(TalesForge.IntentJev TalesForge.Game.NpcReactions TalesForge.LLM)

  # The number of tiles that can be a hot spot.
  @hot_count 5

  @typedoc "The level of a tile: one app, one module or one function."
  @type level :: :app | :module | :function

  @typedoc "The value that sets the color: calls, total time or average time."
  @type metric :: :calls | :total | :avg

  @typedoc """
  One tile of the heat map. `heat` is from 0 to 1 (log scale of `value`).
  `hot` is true for a hot spot. `ai` is true for a module that makes AI calls.
  """
  @type tile :: %{
          key: String.t(),
          label: String.t(),
          app: String.t(),
          module: String.t() | nil,
          calls: non_neg_integer(),
          time_us: non_neg_integer(),
          avg_us: float(),
          value: number(),
          heat: float(),
          hot: boolean(),
          ai: boolean()
        }

  @typedoc "One line of the AI call summary: count and time, no money."
  @type ai_line :: %{
          call_type: String.t(),
          purpose: String.t(),
          calls: non_neg_integer(),
          total_ms: non_neg_integer(),
          avg_ms: float()
        }

  @doc "Returns the value of config key `key` (see the moduledoc)."
  @spec config(atom()) :: term()
  def config(key) do
    :ex_tales_forge
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, Keyword.fetch!(@defaults, key))
  end

  @doc """
  True when the heat map runs on this app. It is always false on production.

      iex> TalesForge.CodeHeat.enabled?(:production)
      false
  """
  @spec enabled?(AppRole.role()) :: boolean()
  def enabled?(role \\ AppRole.role())
  def enabled?(:production), do: false
  def enabled?(_role), do: config(:enabled) == true

  @doc """
  Returns the modules to trace: the app's own loaded modules, without the
  heat map's own modules and the Mix tasks, at most `:max_modules`.
  """
  @spec traced_modules() :: [module()]
  def traced_modules do
    (Application.spec(@app, :modules) || [])
    |> Enum.reject(&skip?/1)
    |> Enum.filter(&Code.ensure_loaded?/1)
    |> Enum.take(config(:max_modules))
  end

  defp skip?(module) do
    name = Atom.to_string(module)

    String.starts_with?(name, ["Elixir.TalesForge.CodeHeat", "Elixir.Mix.Tasks."])
  end

  @doc """
  Writes one sample. `totals` maps `{module, function, arity}` to
  `{calls, time_us}`. The sample keeps the `:max_rows` functions with the
  most time. Then the oldest samples above `:keep` are deleted.
  """
  @spec save(map(), DateTime.t(), DateTime.t(), non_neg_integer()) ::
          {:ok, CodeHeatSnapshot.t()} | {:error, Ecto.Changeset.t()}
  def save(totals, started_at, ended_at, modules) do
    rows =
      totals
      |> Enum.map(fn {{m, f, a}, {calls, time_us}} ->
        %{
          "app" => app_of(m),
          "module" => inspect(m),
          "function" => "#{f}/#{a}",
          "calls" => calls,
          "time_us" => time_us
        }
      end)
      |> Enum.sort_by(& &1["time_us"], :desc)
      |> Enum.take(config(:max_rows))

    result =
      %CodeHeatSnapshot{}
      |> CodeHeatSnapshot.changeset(%{
        app_name: AppRole.app_name(),
        started_at: started_at,
        ended_at: ended_at,
        modules: modules,
        rows: rows
      })
      |> Repo.insert()

    with {:ok, _snapshot} <- result, do: prune()
    result
  end

  defp app_of(module) do
    case Application.get_application(module) do
      nil -> Atom.to_string(@app)
      app -> Atom.to_string(app)
    end
  end

  defp prune do
    keep =
      from(s in CodeHeatSnapshot,
        order_by: [desc: s.ended_at],
        limit: ^config(:keep),
        select: s.id
      )

    Repo.delete_all(from(s in CodeHeatSnapshot, where: s.id not in subquery(keep)))
  end

  @doc "Returns the newest sample, or nil when there is no sample."
  @spec latest() :: CodeHeatSnapshot.t() | nil
  def latest do
    Repo.one(from(s in CodeHeatSnapshot, order_by: [desc: s.ended_at], limit: 1))
  end

  @doc """
  Returns the tiles of `rows` (the rows of a sample) at `level`, colored by
  `metric`. Options: `:module` (a part of the module name, any case) and
  `:min` (the minimum value of `metric`). The tiles are sorted by value,
  the highest first. The #{@hot_count} highest tiles with a heat of 0.5 or
  more are hot spots.

      iex> rows = [
      ...>   %{"app" => "a", "module" => "M", "function" => "f/1", "calls" => 10, "time_us" => 50},
      ...>   %{"app" => "a", "module" => "N", "function" => "g/0", "calls" => 1, "time_us" => 5}
      ...> ]
      iex> TalesForge.CodeHeat.tiles(rows, :module, :calls) |> Enum.map(&{&1.label, &1.value})
      [{"M", 10}, {"N", 1}]
      iex> TalesForge.CodeHeat.tiles(rows, :app, :total) |> Enum.map(&{&1.label, &1.value})
      [{"a", 55}]
      iex> TalesForge.CodeHeat.tiles(rows, :function, :calls, module: "n") |> Enum.map(& &1.label)
      ["N.g/0"]
  """
  @spec tiles([map()], level(), metric(), keyword()) :: [tile()]
  def tiles(rows, level, metric, opts \\ []) do
    filter = opts |> Keyword.get(:module, "") |> to_string() |> String.trim() |> String.downcase()
    min = Keyword.get(opts, :min, 0) || 0

    tiles =
      rows
      |> Enum.filter(&(filter == "" or String.contains?(String.downcase(&1["module"]), filter)))
      |> Enum.group_by(&group_key(&1, level))
      |> Enum.map(fn {key, group} -> tile(key, group, level, metric) end)
      |> Enum.filter(&(&1.value >= min))
      |> Enum.sort_by(& &1.value, :desc)

    max = tiles |> Enum.map(& &1.value) |> Enum.max(fn -> 0 end)

    tiles
    |> Enum.with_index()
    |> Enum.map(fn {tile, rank} ->
      heat = heat(tile.value, max)
      %{tile | heat: heat, hot: rank < @hot_count and heat >= 0.5 and tile.value > 0}
    end)
  end

  defp group_key(row, :app), do: row["app"]
  defp group_key(row, :module), do: row["module"]
  defp group_key(row, :function), do: row["module"] <> "." <> row["function"]

  defp tile(key, [first | _] = group, level, metric) do
    calls = group |> Enum.map(& &1["calls"]) |> Enum.sum()
    time_us = group |> Enum.map(& &1["time_us"]) |> Enum.sum()
    avg_us = if calls > 0, do: time_us / calls, else: 0.0
    module = if level == :app, do: nil, else: first["module"]

    %{
      key: key,
      label: key,
      app: first["app"],
      module: module,
      calls: calls,
      time_us: time_us,
      avg_us: avg_us,
      value: value(metric, calls, time_us, avg_us),
      heat: 0.0,
      hot: false,
      ai: module in @ai_modules
    }
  end

  defp value(:calls, calls, _time, _avg), do: calls
  defp value(:total, _calls, time_us, _avg), do: time_us
  defp value(:avg, _calls, _time, avg_us), do: Float.round(avg_us, 1)

  @doc """
  Returns the heat of `value` from 0 to 1 on a log scale, where `max` is 1.

      iex> TalesForge.CodeHeat.heat(0, 100)
      0.0
      iex> TalesForge.CodeHeat.heat(100, 100)
      1.0
  """
  @spec heat(number(), number()) :: float()
  def heat(value, max) when max > 0 and value > 0,
    do: Float.round(:math.log(1 + value) / :math.log(1 + max), 3)

  def heat(_value, _max), do: 0.0

  @doc """
  Returns the AI calls (Jev and LLM) since `since`, grouped by call type and
  purpose: the number of calls and the time in milliseconds. It shows no
  money.
  """
  @spec ai_calls(DateTime.t()) :: [ai_line()]
  def ai_calls(since) do
    from(c in AICall,
      where: c.call_type in ["jev", "llm"] and c.inserted_at >= ^since,
      group_by: [c.call_type, c.purpose],
      select: %{
        call_type: c.call_type,
        purpose: c.purpose,
        calls: count(c.id),
        total_ms: coalesce(sum(c.latency_ms), 0)
      }
    )
    |> Repo.all()
    |> Enum.map(fn line ->
      total = to_int(line.total_ms)

      %{line | total_ms: total, purpose: line.purpose || "(none)"}
      |> Map.put(:avg_ms, Float.round(total / max(line.calls, 1), 1))
    end)
    |> Enum.sort_by(& &1.total_ms, :desc)
  end

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_integer(n), do: n
end
