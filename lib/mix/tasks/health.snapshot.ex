defmodule Mix.Tasks.Health.Snapshot do
  @shortdoc "Appends this merge's code health row to docs/health/history.csv and redraws trend.svg"
  @moduledoc """
  The code health history: one row per merge to main in
  `docs/health/history.csv`, drawn as `docs/health/trend.svg`.

  `mix health.snapshot` measures HEAD (`mix health.check`'s numbers), takes
  the date and the PR number from HEAD's commit (`--pr` and `--date`
  override them), puts the row in the CSV (a row for the same PR is
  replaced) and redraws the chart. Run it by hand after a merge to main
  when you want a new history row. The old
  `.github/workflows/health-snapshot.yml` workflow that opened a rolling
  PR was removed in hobby mode.

      mix health.snapshot
      mix health.snapshot --pr 326 --date 2026-10-17T06:01:43+02:00
      mix health.snapshot --keep /tmp/branch.csv

  `--keep FILE` also keeps the rows of another history file whose PR the
  CSV does not have (in date order). Use it when combining two history
  files so a conflict that kept main's side loses no row.

  `--out FILE` writes only the measured row to FILE (a one-row CSV) and
  leaves the history alone; `--row FILE` puts FILE's rows in the history
  instead of measuring. Measure a merge with `--out`, then add the row
  with `--row`, so close-together merges can each add their row.

      mix health.snapshot --out /tmp/row.csv
      mix health.snapshot --row /tmp/row.csv --keep /tmp/branch.csv
  """
  use Mix.Task

  alias Mix.Tasks.Health.Check

  @csv "docs/health/history.csv"
  @svg "docs/health/trend.svg"

  @columns ~w(date pr cycles largest_cycle compile_connected_cycles compile_connected_largest
              web_refs complex_functions params_4plus counting)

  @impl Mix.Task
  def run(args) do
    {parsed, _} =
      OptionParser.parse!(args,
        strict: [pr: :integer, date: :string, keep: :string, out: :string, row: :string]
      )

    opts = Map.new(parsed)
    new = if opts[:row], do: read(opts.row), else: [measure(opts)]
    write(new, opts)
  end

  # --out: only the new rows, as their own CSV.
  defp write(new, %{out: out}), do: File.write!(out, csv(new))

  defp write(new, opts) do
    kept = if opts[:keep], do: read(opts.keep), else: []
    rows = Enum.reduce(new, @csv |> read() |> keep_rows(kept), &put_row(&2, &1))
    File.write!(@csv, csv(rows))
    File.write!(@svg, svg(rows))

    Mix.shell().info(
      "Wrote #{@csv} (PR #{Enum.map_join(new, ", ", &"##{&1["pr"]}")}) and #{@svg}"
    )
  end

  defp measure(opts) do
    {pr, date} = head_commit()
    row(Check.collect(), opts[:date] || date, opts[:pr] || pr)
  end

  # The PR number and date of HEAD: "Merge pull request #85 from ..." or a
  # squash merge "Title (#57)".
  defp head_commit do
    {out, 0} = System.cmd("git", ["log", "-1", "--format=%cI%n%s"])
    [date, subject] = String.split(out, "\n", parts: 2)
    {pr_of(subject), date}
  end

  @doc """
  The PR number in a merge commit's subject, or nil.

      iex> Mix.Tasks.Health.Snapshot.pr_of("Merge pull request #85 from whyse-ab/x")
      85
      iex> Mix.Tasks.Health.Snapshot.pr_of("Chat: delete a message (#57)")
      57
      iex> Mix.Tasks.Health.Snapshot.pr_of("Fix a typo")
      nil
  """
  @spec pr_of(String.t()) :: pos_integer() | nil
  def pr_of(subject) do
    case Regex.run(~r/#(\d+)/, subject) do
      [_, n] -> String.to_integer(n)
      nil -> nil
    end
  end

  @doc "One history row from `mix health.check`'s numbers (`Check.collect/0`)."
  @spec row(map(), String.t(), pos_integer() | nil) :: %{String.t() => term()}
  def row(numbers, date, pr) do
    s = numbers["summary"]

    %{
      "date" => date,
      "pr" => pr,
      "cycles" => s["cycle_count"]["all"],
      "largest_cycle" => s["largest_cycle"]["all"],
      "compile_connected_cycles" => s["cycle_count"]["compile-connected"],
      "compile_connected_largest" => s["largest_cycle"]["compile-connected"],
      "web_refs" => s["web_reference_edges"],
      "complex_functions" => s["complex_function_count"],
      "params_4plus" => s["wide_function_count"],
      "counting" => numbers["counting"]
    }
  end

  @doc "Adds the rows of `kept` whose PR is not in `rows`, in date order."
  @spec keep_rows([map()], [map()]) :: [map()]
  def keep_rows(rows, kept) do
    prs = MapSet.new(rows, & &1["pr"])

    case Enum.reject(kept, &(&1["pr"] in prs)) do
      [] -> rows
      extra -> Enum.sort_by(rows ++ extra, & &1["date"])
    end
  end

  @doc """
  Puts `row` in place of the row of the same PR, else after the rows with
  an earlier or the same date (merge order, also when the runs for two
  merges finish in the other order).
  """
  @spec put_row([map()], map()) :: [map()]
  def put_row(rows, row) do
    case Enum.find_index(rows, &(row["pr"] != nil and &1["pr"] == row["pr"])) do
      nil ->
        {before, later} = Enum.split_while(rows, &(instant(&1) <= instant(row)))
        before ++ [row] ++ later

      i ->
        List.replace_at(rows, i, row)
    end
  end

  defp instant(%{"date" => date}) do
    case DateTime.from_iso8601(date) do
      {:ok, at, _offset} -> DateTime.to_unix(at)
      {:error, _} -> date
    end
  end

  @doc "The rows of a history CSV file (none when it is missing)."
  @spec read(Path.t()) :: [map()]
  def read(path) do
    case File.read(path) do
      {:ok, text} -> parse(text)
      {:error, :enoent} -> []
    end
  end

  @doc """
  The rows of history CSV text. Numbers come back as integers.

      iex> Mix.Tasks.Health.Snapshot.parse("date,pr,cycles\\n2026-10-17,85,64\\n")
      [%{"date" => "2026-10-17", "pr" => 85, "cycles" => 64}]
  """
  @spec parse(String.t()) :: [map()]
  def parse(text) do
    [header | lines] = String.split(text, "\n", trim: true)
    keys = String.split(header, ",")

    for line <- lines do
      keys
      |> Enum.zip(String.split(line, ","))
      |> Map.new(fn
        {"date", v} -> {"date", v}
        {k, ""} -> {k, nil}
        {k, v} -> {k, String.to_integer(v)}
      end)
    end
  end

  @doc "The rows as CSV text."
  @spec csv([map()]) :: String.t()
  def csv(rows) do
    lines = for r <- rows, do: Enum.map_join(@columns, ",", &to_string(r[&1]))
    Enum.join([Enum.join(@columns, ",") | lines], "\n") <> "\n"
  end

  # Bottom to top.
  @segments [
    {"cycles", "xref cycles", "#b91c1c"},
    {"complex_functions", "complex functions", "#15803d"},
    {"web_refs", "domain-to-web refs", "#7c3aed"},
    {"params_4plus", "functions with 4+ params", "#b45309"}
  ]

  @w 920
  @h 420
  @pad %{l: 48, r: 170, t: 48, b: 40}
  @plot_h @h - @pad.t - @pad.b
  # The least room between two x-axis names on one line.
  @label_gap 36

  @doc """
  The rows as a stacked bar chart: one bar per merge, its segments xref
  cycles, complex functions, domain-to-web refs and functions with 4+
  parameters (bottom to top). Every bar is drawn, and a thin dashed line
  joins a segment's top to the same segment's top on the next bar. Only
  the bars of `labelled/1` show their segment values and their total on
  top; two of them closer than @label_gap set their numbers apart, the
  first ending at its bar's right edge and the second starting at its
  bar's left edge. The SVG text is plain ASCII.
  A bar whose `counting` differs from the bar before it (a row without one
  counts as 1) gets a grey dashed line topped with its counting version
  ("v2"), which the legend names "counting changed": that drop or rise
  comes from how `mix health.check` counts, not from the code. The x-axis
  names only the bars of `labelled/1` (the first, the last and each
  counting change); a name too close to the one before it goes one line
  lower.
  """
  @spec svg([map()]) :: String.t()
  def svg(rows) do
    g = geometry(rows)
    tops = Enum.map(rows, &segment_tops/1)

    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{@w}" height="#{@h}" viewBox="0 0 #{@w} #{@h}" font-family="sans-serif" font-size="11" fill="#374151">
    <rect width="#{@w}" height="#{@h}" fill="#ffffff"/>
    <text x="#{@pad.l}" y="24" font-size="15" font-weight="bold">Tales Forge code health per merge to main: total, lower is better</text>
    #{grid(g)}
    #{marks(rows, g)}
    #{rows |> Enum.zip(tops) |> Enum.with_index() |> Enum.map_join("\n", &bar(&1, g))}
    #{links(tops, g)}
    #{axis(rows, g)}
    #{legend()}
    </svg>
    """
  end

  # The scale: the top value, the slot of one bar and the bar width.
  defp geometry(rows) do
    top = rows |> Enum.map(&total/1) |> Enum.max(fn -> 10 end) |> ceil_to(20) |> max(20)
    slot = (@w - @pad.l - @pad.r) / max(length(rows), 1)
    shown = labelled(rows)
    %{top: top, slot: slot, bar: slot * 0.6, align: align(shown, slot)}
  end

  # How each labelled bar's numbers sit: centred, or, for two labelled bars
  # closer than @label_gap, the first ends at its bar's right edge and the
  # second starts at its bar's left edge, so the two never overlap.
  defp align(shown, slot) do
    close =
      for {a, b} <- Enum.zip(shown, Enum.drop(shown, 1)), (b - a) * slot < @label_gap, do: {a, b}

    Enum.reduce(close, Map.new(shown, &{&1, :middle}), fn {a, b}, acc ->
      acc |> Map.put(a, :end) |> Map.put(b, :start)
    end)
  end

  # The x and text-anchor of bar i's numbers; nil when the bar shows none.
  defp anchor(g, i) do
    case g.align[i] do
      nil -> nil
      :middle -> {x(g, i) + g.bar / 2, "middle"}
      :end -> {x(g, i) + g.bar, "end"}
      :start -> {x(g, i), "start"}
    end
  end

  defp x(g, i), do: @pad.l + i * g.slot + (g.slot - g.bar) / 2
  defp y(g, v), do: @pad.t + @plot_h * (1 - v / g.top)

  defp grid(%{top: top} = g) do
    Enum.map_join(0..top//div(top, 4), "\n", fn v ->
      ~s|<line x1="#{@pad.l}" y1="#{f(y(g, v))}" x2="#{@w - @pad.r}" y2="#{f(y(g, v))}" stroke="#e5e7eb"/>| <>
        ~s|<text x="#{@pad.l - 6}" y="#{f(y(g, v) + 4)}" text-anchor="end">#{v}</text>|
    end)
  end

  # Every bar is drawn; only the labelled bars (`labelled/1`) show their
  # segment numbers and the total on top.
  defp bar({{row, segs}, i}, g) do
    Enum.join(
      for {{k, _, color}, {from, to}} <- Enum.zip(@segments, segs),
          to > from,
          do: segment(g, i, row[k], color, {from, to})
    ) <> bar_total(g, i, total(row))
  end

  # The bold total on top of bar i, when the bar is labelled.
  defp bar_total(g, i, value) do
    case anchor(g, i) do
      nil ->
        ""

      {tx, side} ->
        haloed(
          ~s|x="#{f(tx)}" y="#{f(y(g, value) - 5)}" text-anchor="#{side}" font-weight="bold"|,
          value,
          ""
        )
    end
  end

  # A number with a white halo, so it reads over a bar or a dashed line. The
  # halo is its own text under the number: not every SVG renderer knows
  # paint-order.
  defp haloed(at, value, fill) do
    ~s|<text #{at} fill="#ffffff" stroke="#ffffff" stroke-width="3">#{value}</text>| <>
      ~s|<text #{at}#{fill}>#{value}</text>|
  end

  @doc """
  The indexes of the bars the x-axis names: the first, the last and each
  bar whose `counting` differs from the bar before it (blank is 1).

      iex> Mix.Tasks.Health.Snapshot.labelled([%{}, %{}, %{"counting" => 2}, %{"counting" => 2}, %{"counting" => 2}])
      [0, 2, 4]
  """
  @spec labelled([map()]) :: [non_neg_integer()]
  def labelled([]), do: []

  def labelled(rows) do
    Enum.uniq([0 | changes(rows)] ++ [length(rows) - 1])
  end

  # The index of each bar whose counting differs from the bar before it.
  defp changes(rows) do
    counts = Enum.map(rows, &(&1["counting"] || 1))

    for {{a, b}, i} <- counts |> Enum.zip(Enum.drop(counts, 1)) |> Enum.with_index(1),
        a != b,
        do: i
  end

  # The PR names under the bars of `labelled/1`. A name closer than
  # @label_gap to the last name on the first line goes on the second.
  defp axis(rows, g) do
    {texts, _} =
      rows
      |> labelled()
      |> Enum.map_reduce(%{}, fn i, last ->
        cx = x(g, i) + g.bar / 2
        line = if cx - Map.get(last, 0, -@label_gap) < @label_gap, do: 1, else: 0
        y = @h - @pad.b + 16 + line * 13

        {~s|<text x="#{f(cx)}" y="#{y}" text-anchor="middle">##{Enum.at(rows, i)["pr"]}</text>|,
         Map.put(last, line, cx)}
      end)

    Enum.join(texts, "\n")
  end

  # One segment, with its value on a labelled bar: dark with a white halo,
  # so it reads over any bar. A thin segment gets a smaller number.
  defp segment(g, i, value, color, {from, to}) do
    {low, high} = {y(g, from), y(g, to)}
    size = (low - high - 1) |> min(10) |> max(6) |> round()

    rect =
      ~s|<rect x="#{f(x(g, i))}" y="#{f(high)}" width="#{f(g.bar)}" height="#{f(low - high)}" fill="#{color}"/>|

    case anchor(g, i) do
      nil ->
        rect

      {tx, side} ->
        at =
          ~s|x="#{f(tx)}" y="#{f((low + high) / 2 + size * 0.35)}" text-anchor="#{side}" font-size="#{size}"|

        rect <> haloed(at, value, ~s| fill="#111827"|)
    end
  end

  # A thin dashed line from each segment's top to its top on the next bar.
  defp links(tops, %{bar: bar} = g) do
    pairs = tops |> Enum.zip(Enum.drop(tops, 1)) |> Enum.with_index()

    Enum.map_join(
      for({{a, b}, i} <- pairs, seg <- Enum.zip([@segments, a, b]), do: {i, seg}),
      "\n",
      fn {i, {{_, _, color}, {_, ta}, {_, tb}}} ->
        ~s|<line x1="#{f(x(g, i) + bar)}" y1="#{f(y(g, ta))}" x2="#{f(x(g, i + 1))}" y2="#{f(y(g, tb))}" stroke="#{color}" stroke-width="1" stroke-dasharray="3 3"/>|
      end
    )
  end

  # A grey dashed line left of each bar where the counting changed, with
  # the new counting version on top.
  defp marks(rows, g) do
    for i <- changes(rows), into: "" do
      line_x = f(@pad.l + i * g.slot)

      ~s|<line x1="#{line_x}" y1="#{@pad.t - 8}" x2="#{line_x}" y2="#{@h - @pad.b}" stroke="#6b7280" stroke-width="1" stroke-dasharray="2 4"/>| <>
        ~s|<text x="#{line_x}" y="#{@pad.t - 12}" text-anchor="middle" font-size="10" fill="#6b7280">v#{Enum.at(rows, i)["counting"] || 1}</text>|
    end
  end

  defp legend do
    n = length(@segments)

    @segments
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {{_, name, color}, j} ->
      ~s|<rect x="#{@w - @pad.r + 16}" y="#{@pad.t + j * 22}" width="12" height="12" fill="#{color}"/>| <>
        ~s|<text x="#{@w - @pad.r + 34}" y="#{@pad.t + j * 22 + 11}">#{name}</text>|
    end)
    |> Kernel.<>(
      ~s|\n<line x1="#{@w - @pad.r + 22}" y1="#{@pad.t + n * 22}" x2="#{@w - @pad.r + 22}" y2="#{@pad.t + n * 22 + 12}" stroke="#6b7280" stroke-width="1" stroke-dasharray="2 2"/>| <>
        ~s|<text x="#{@w - @pad.r + 34}" y="#{@pad.t + n * 22 + 11}">counting changed (vN)</text>|
    )
  end

  defp total(row), do: Enum.sum(for {k, _, _} <- @segments, do: row[k] || 0)

  # The {bottom, top} value of each segment of `row`, bottom first.
  defp segment_tops(row) do
    {segs, _} =
      Enum.map_reduce(@segments, 0, fn {k, _, _}, at ->
        {{at, at + (row[k] || 0)}, at + (row[k] || 0)}
      end)

    segs
  end

  defp ceil_to(v, step), do: div(v + step - 1, step) * step
  defp f(v), do: :erlang.float_to_binary(v / 1, decimals: 1)
end
