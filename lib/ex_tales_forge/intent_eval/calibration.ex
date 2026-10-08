defmodule TalesForge.IntentEval.Calibration do
  @moduledoc """
  Fits the Jev intent confidence map (`TalesForge.Game.IntentCalibration`) on
  eval readings, and measures it honestly.

  `fit/2` runs isotonic regression (pool-adjacent-violators) of "the action
  read was right" (1/0) on the raw confidence, then merges blocks smaller than
  `:min_block` items, so no knot rests on a handful of items. Each block becomes
  a knot at its mean raw confidence and its Laplace-smoothed accuracy
  (`(right + 1) / (n + 2)`, so a block of all-right reads never claims
  certainty). Raw 0, Jev's uniform guess, is pinned to the chance rate over the
  16 action labels (`:floor`), not to the lowest block. The map interpolates
  linearly between knots.

  An in-sample ECE of a map fitted on the same items flatters it, so
  `cross_validated/3` also reports the ECE of maps fitted on k−1 folds and
  applied to the held-out fold (folds by a hash of the item id, so they are
  stable). Only the tune split is ever used to fit.
  """

  alias TalesForge.Game.IntentCalibration
  alias TalesForge.IntentEval.Metrics

  # Chance accuracy over the 16 action labels: where a raw confidence of 0
  # (a uniform guess) is pinned.
  @floor Float.round(1 / 16, 4)

  @typedoc "One point: the raw confidence and whether the action read was right."
  @type point :: {float(), boolean()}

  @doc """
  The calibration map fitted on `points`: `%{"points" => [[x, y], ...]}` with
  `x` and `y` rounded to 4 places. `opts`: `:min_block` (default 15) and
  `:floor`, the calibrated value at raw 0 (default 1/16).
  """
  @spec fit([point()], keyword()) :: IntentCalibration.t()
  def fit(points, opts \\ []) do
    min_block = Keyword.get(opts, :min_block, 15)

    knots =
      points
      |> Enum.sort_by(fn {x, _} -> x end)
      |> Enum.map(fn {x, ok?} -> %{n: 1, sx: x / 1, sy: if(ok?, do: 1.0, else: 0.0)} end)
      |> pav()
      |> merge_small(min_block)
      |> pav()
      |> Enum.map(fn b -> {b.sx / b.n, (b.sy + 1) / (b.n + 2)} end)
      |> monotone()
      |> anchor(Keyword.get(opts, :floor, @floor))
      |> Enum.map(fn {x, y} -> [Float.round(x, 4), Float.round(y, 4)] end)

    %{"points" => knots}
  end

  # Laplace smoothing can break monotonicity between blocks of different sizes;
  # a running maximum restores it.
  defp monotone(knots) do
    knots
    |> Enum.map_reduce(0.0, fn {x, y}, acc -> {{x, max(y, acc)}, max(y, acc)} end)
    |> elem(0)
  end

  # Pins raw 0 (Jev's uniform guess) to the chance rate rather than clamping it
  # to the lowest block, and raw 1 to the top block.
  defp anchor([], floor), do: [{0.0, floor}, {1.0, floor}]

  defp anchor(knots, floor) do
    [{x0, _} | _] = knots
    {x1, y1} = List.last(knots)
    head = if x0 > 0.0, do: [{0.0, floor}], else: []
    tail = if x1 < 1.0, do: [{1.0, y1}], else: []
    head ++ knots ++ tail
  end

  # Pool adjacent violators: merge neighbouring blocks until the block means
  # are strictly increasing (ties merge too, so a long run of right reads is one
  # large block and its smoothed accuracy stays close to its real one).
  defp pav(blocks) do
    blocks
    |> Enum.reduce([], fn block, stack -> push(stack, block) end)
    |> Enum.reverse()
  end

  defp push([top | rest], block) do
    if top.sy / top.n >= block.sy / block.n,
      do: push(rest, merge(top, block)),
      else: [block, top | rest]
  end

  defp push([], block), do: [block]

  defp merge(a, b), do: %{n: a.n + b.n, sx: a.sx + b.sx, sy: a.sy + b.sy}

  # Merges each block smaller than `min` into its neighbour (the next one, or
  # the previous one at the end).
  defp merge_small(blocks, min) do
    blocks
    |> Enum.reduce([], fn
      block, [prev | rest] when prev.n < min -> [merge(prev, block) | rest]
      block, stack -> [block | stack]
    end)
    |> case do
      [last, prev | rest] when last.n < min -> [merge(prev, last) | rest]
      stack -> stack
    end
    |> Enum.reverse()
  end

  @doc """
  Expected calibration error over 10 equal-width bins of `points`, where each
  point is `{confidence, correct?}`. `nil` for no points.
  """
  @spec ece([point()]) :: float() | nil
  def ece([]), do: nil

  def ece(points) do
    total = length(points)

    points
    |> Enum.group_by(fn {c, _} -> min(trunc(c * 10), 9) end)
    |> Enum.reduce(0.0, fn {_bin, items}, acc ->
      n = length(items)
      conf = items |> Enum.map(&elem(&1, 0)) |> Enum.sum() |> Kernel./(n)
      acc_rate = Enum.count(items, &elem(&1, 1)) / n
      acc + n / total * abs(acc_rate - conf)
    end)
  end

  @doc """
  The ECE of maps fitted on `k - 1` folds and applied to the held-out fold,
  pooled over all folds. `keyed` is a list of `{id, raw_confidence, correct?}`.
  """
  @spec cross_validated([{String.t(), float(), boolean()}], pos_integer(), keyword()) ::
          float() | nil
  def cross_validated(keyed, k \\ 5, opts \\ []) do
    folds = Enum.group_by(keyed, fn {id, _, _} -> :erlang.phash2(id, k) end)

    folds
    |> Enum.flat_map(fn {fold, held_out} ->
      train =
        folds
        |> Enum.reject(fn {f, _} -> f == fold end)
        |> Enum.flat_map(fn {_f, items} -> items end)
        |> Enum.map(fn {_id, x, ok?} -> {x, ok?} end)

      map = fit(train, opts)
      Enum.map(held_out, fn {_id, x, ok?} -> {IntentCalibration.apply(x, map), ok?} end)
    end)
    |> ece()
  end

  @doc """
  Fits a versioned map on the Jev readings of scored eval items (`scored` as in
  `TalesForge.IntentEval.run/1`'s results) and measures it.

  Uses each OK Jev reading's `raw_confidence` against `Metrics.action_correct?/2`.
  Returns `{map, stats}`: `map` carries `version`, `method`, `fitted_on`, `n`,
  `min_block` and `points`; `stats` has `n` and the raw, in-sample and
  cross-validated ECE. `opts`: `:version` (required), `:fitted_on` (default
  `"tune"`), `:min_block` (default 15), `:folds` (default 5).
  """
  @spec fit_scored([map()], keyword()) :: {IntentCalibration.t(), map()}
  def fit_scored(scored, opts) do
    min_block = Keyword.get(opts, :min_block, 15)

    keyed =
      for %{item: item, readings: %{jev: r}} <- scored,
          r.status == :ok,
          is_number(Map.get(r, :raw_confidence)),
          not is_nil(r.action),
          do: {item["id"], r.raw_confidence / 1, Metrics.action_correct?(item, r)}

    points = Enum.map(keyed, fn {_id, x, ok?} -> {x, ok?} end)
    fitted = fit(points, min_block: min_block)

    map =
      Map.merge(fitted, %{
        "version" => Keyword.fetch!(opts, :version),
        "method" => "isotonic (PAV), action-correct on raw Jev confidence",
        "fitted_on" => Keyword.get(opts, :fitted_on, "tune"),
        "n" => length(points),
        "min_block" => min_block
      })

    stats = %{
      n: length(points),
      raw_ece: ece(points),
      in_sample_ece:
        points |> Enum.map(fn {x, ok?} -> {IntentCalibration.apply(x, map), ok?} end) |> ece(),
      cv_ece: cross_validated(keyed, Keyword.get(opts, :folds, 5), min_block: min_block)
    }

    {map, stats}
  end
end
