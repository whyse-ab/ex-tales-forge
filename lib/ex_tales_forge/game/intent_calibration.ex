defmodule TalesForge.Game.IntentCalibration do
  @moduledoc """
  Maps the Jev intent read's raw confidence to a calibrated one: the measured
  chance that the action read is right.

  Jev's confidence is its top probability rescaled so that a uniform guess is 0
  (`Jev.confidence/2`); over 16 action labels that reads low, so the raw value
  is under-confident. The map is a monotonic, piecewise-linear curve fitted
  on the eval set's **tune split** (isotonic regression, pool-adjacent-violators,
  `TalesForge.IntentEval.Calibration.fit/2`) and stored as data in
  `priv/intent/calibration.json` with a version. A monotonic map never changes
  which reading is on top; it only moves the confidence the act / ask bands
  (`TalesForge.Game.IntentClarification`) compare against.

  The file is read at compile time (`@external_resource`), so a new fit is a
  data change plus a rebuild. `version/0` is logged with every read.
  """

  @path Path.join([__DIR__, "..", "..", "..", "priv", "intent", "calibration.json"])
        |> Path.expand()
  @external_resource @path

  @map (case File.read(@path) do
          {:ok, body} -> Jason.decode!(body)
          {:error, _} -> %{"version" => "identity", "points" => [[0.0, 0.0], [1.0, 1.0]]}
        end)

  @typedoc "A calibration map: a `version` and sorted `[x, y]` knots."
  @type t :: %{required(String.t()) => term()}

  @doc "The calibration map compiled into the release."
  @spec map() :: t()
  def map, do: @map

  @doc "The version of the compiled calibration map, for logs and `ai_calls.meta`."
  @spec version() :: String.t()
  def version, do: Map.get(@map, "version", "identity")

  @doc ~S"""
  The calibrated confidence for a raw confidence, by linear interpolation
  between the map's knots and clamped to the first and last knot. `nil` stays
  `nil`.

      iex> map = %{"points" => [[0.0, 0.2], [0.5, 0.8], [1.0, 1.0]]}
      iex> TalesForge.Game.IntentCalibration.apply(0.25, map)
      0.5
      iex> TalesForge.Game.IntentCalibration.apply(2.0, map)
      1.0
      iex> TalesForge.Game.IntentCalibration.apply(nil, map)
      nil
  """
  @spec apply(number() | nil, t()) :: float() | nil
  def apply(raw, map \\ @map)
  def apply(nil, _map), do: nil

  def apply(raw, %{"points" => points}) when is_number(raw) do
    points
    |> Enum.map(fn [x, y] -> {x / 1, y / 1} end)
    |> interpolate(raw / 1)
    |> Float.round(4)
  end

  defp interpolate([{_x, y}], _raw), do: y
  defp interpolate([{x0, y0} | _], raw) when raw <= x0, do: y0

  defp interpolate([{x0, y0}, {x1, y1} | rest], raw) do
    cond do
      raw <= x1 and x1 > x0 -> y0 + (y1 - y0) * (raw - x0) / (x1 - x0)
      raw <= x1 -> y1
      true -> interpolate([{x1, y1} | rest], raw)
    end
  end
end
