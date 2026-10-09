defmodule TalesForge.TeamPage do
  @moduledoc """
  The numbers behind the founders' presentation page (`/team`,
  `TalesForgeWeb.TeamLive`), and the small helpers that turn them into text.

  The numbers live in tales-forge-docs `docs/team-page/data.json`. A snapshot
  of that file is kept in `priv/team/data.json` and read **at compile time**
  (`@external_resource`), so the page does no file or network IO on a request,
  a broken file fails the build and CI instead of the page, and the tests read
  the exact file that ships. Refreshing the numbers is a copy of the docs file
  plus a PR (`priv/team/README.md`).

  Every value is looked up by path (`get/2`). A missing or `null` value means
  "not measured yet": the formatters below render exactly that text and never
  a zero, so the page can't invent a number.
  """

  @data_path Path.expand("../../priv/team/data.json", __DIR__)
  @external_resource @data_path
  @data @data_path |> File.read!() |> Jason.decode!()

  @not_measured "not measured yet"
  @words {"zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
          "eleven", "twelve"}

  @typedoc "A path into the data: map keys and list indexes."
  @type path :: [String.t() | non_neg_integer()]

  @doc "The bundled `data.json`, decoded (string keys)."
  @spec data() :: map()
  def data, do: @data

  @doc "Where the bundled snapshot lives in the source tree."
  @spec data_path() :: String.t()
  def data_path, do: @data_path

  @doc ~S"""
  The text shown for any value we don't have.

      iex> TalesForge.TeamPage.not_measured()
      "not measured yet"
  """
  @spec not_measured() :: String.t()
  def not_measured, do: @not_measured

  @doc """
  The value at `path` in `data`, or `nil` when any step is missing.

      iex> TalesForge.TeamPage.get(%{"a" => [%{"b" => 2}]}, ["a", 0, "b"])
      2
      iex> TalesForge.TeamPage.get(%{"a" => nil}, ["a", "b"])
      nil
      iex> TalesForge.TeamPage.get(%{"a" => [1]}, ["a", 3])
      nil
  """
  @spec get(term(), path()) :: term()
  def get(data, path), do: Enum.reduce_while(path, data, &step/2)

  defp step(key, map) when is_map(map) and is_binary(key), do: cont(Map.get(map, key))
  defp step(index, list) when is_list(list) and is_integer(index), do: cont(Enum.at(list, index))
  defp step(_key, _other), do: {:halt, nil}

  defp cont(nil), do: {:halt, nil}
  defp cont(value), do: {:cont, value}

  @doc """
  True when `value` is an actual measurement (a number or a non-empty
  string), false for `nil`, `""` and anything else.

      iex> TalesForge.TeamPage.measured?(0)
      true
      iex> TalesForge.TeamPage.measured?(nil)
      false
  """
  @spec measured?(term()) :: boolean()
  def measured?(value) when is_number(value), do: true
  def measured?(value) when is_binary(value), do: String.trim(value) != ""
  def measured?(_value), do: false

  @doc """
  A number as text: thousands separated, floats with `:decimals` places (or as
  few as needed when not given). Anything that isn't a number is
  "not measured yet".

      iex> TalesForge.TeamPage.number(1641)
      "1,641"
      iex> TalesForge.TeamPage.number(4.39)
      "4.39"
      iex> TalesForge.TeamPage.number(4.3, decimals: 2)
      "4.30"
      iex> TalesForge.TeamPage.number(nil)
      "not measured yet"
  """
  @spec number(term(), keyword()) :: String.t()
  def number(value, opts \\ [])

  def number(value, opts) when is_integer(value) do
    case opts[:decimals] do
      nil -> delimit(Integer.to_string(value))
      decimals -> number(value * 1.0, decimals: decimals)
    end
  end

  def number(value, opts) when is_float(value) do
    decimals = opts[:decimals] || decimals_needed(value)
    [int | frac] = value |> :erlang.float_to_binary(decimals: decimals) |> String.split(".")
    Enum.join([delimit(int) | frac], ".")
  end

  def number(_value, _opts), do: @not_measured

  @doc """
  US dollars: two decimals, more for amounts under a dollar that need them.

      iex> TalesForge.TeamPage.usd(44.54)
      "$44.54"
      iex> TalesForge.TeamPage.usd(25)
      "$25"
      iex> TalesForge.TeamPage.usd(0.00013)
      "$0.00013"
      iex> TalesForge.TeamPage.usd(nil)
      "not measured yet"
  """
  @spec usd(term()) :: String.t()
  def usd(value) when is_integer(value), do: "$" <> number(value)

  def usd(value) when is_float(value),
    do: "$" <> number(value, decimals: max(2, decimals_needed(value)))

  def usd(_value), do: @not_measured

  @doc """
  A percentage (`46` -> "46%").

      iex> TalesForge.TeamPage.pct(85.76)
      "85.76%"
      iex> TalesForge.TeamPage.pct(nil)
      "not measured yet"
  """
  @spec pct(term()) :: String.t()
  def pct(value) when is_number(value), do: number(value) <> "%"
  def pct(_value), do: @not_measured

  @doc """
  Milliseconds (`255` -> "255 ms").

      iex> TalesForge.TeamPage.ms(1500)
      "1,500 ms"
  """
  @spec ms(term()) :: String.t()
  def ms(value) when is_number(value), do: number(value) <> " ms"
  def ms(_value), do: @not_measured

  @doc """
  A score on the 1-5 scale with one decimal (`4.26` -> "4.3/5").

      iex> TalesForge.TeamPage.score(4.26)
      "4.3/5"
      iex> TalesForge.TeamPage.score(nil)
      "not measured yet"
  """
  @spec score(term()) :: String.t()
  def score(value) when is_number(value), do: number(value * 1.0, decimals: 1) <> "/5"
  def score(_value), do: @not_measured

  @doc """
  A low-high range of numbers with a unit (`6`, `9`, "s" -> "6-9 s", with an
  en dash).

      iex> TalesForge.TeamPage.range(0.3, 0.6, "s")
      "0.3–0.6 s"
      iex> TalesForge.TeamPage.range(nil, 0.6, "s")
      "not measured yet"
  """
  @spec range(term(), term(), String.t()) :: String.t()
  def range(low, high, unit) when is_number(low) and is_number(high),
    do: "#{number(low)}–#{number(high)} #{unit}"

  def range(_low, _high, _unit), do: @not_measured

  @doc """
  A small count as a word ("three bots"), the number itself above twelve,
  "not measured yet" for anything else.

      iex> TalesForge.TeamPage.count_word(3)
      "three"
      iex> TalesForge.TeamPage.count_word(40)
      "40"
  """
  @spec count_word(term()) :: String.t()
  def count_word(n) when is_integer(n) and n in 0..12,
    do: elem(@words, n)

  def count_word(n) when is_integer(n), do: number(n)
  def count_word(_n), do: @not_measured

  @doc """
  An ISO date as a long label (`"2026-10-09"` -> "9 Oct 2026"), or
  "not measured yet".

      iex> TalesForge.TeamPage.date_label("2026-10-09")
      "9 Oct 2026"
      iex> TalesForge.TeamPage.date_label(nil)
      "not measured yet"
  """
  @spec date_label(term()) :: String.t()
  def date_label(iso) do
    case parse_date(iso) do
      {:ok, date} -> Calendar.strftime(date, "%-d %b %Y")
      :error -> @not_measured
    end
  end

  @doc """
  An ISO date as a short chart label (`"2026-10-07"` -> "Oct 7").

      iex> TalesForge.TeamPage.short_date("2026-10-07")
      "Oct 7"
  """
  @spec short_date(term()) :: String.t()
  def short_date(iso) do
    case parse_date(iso) do
      {:ok, date} -> Calendar.strftime(date, "%b %-d")
      :error -> @not_measured
    end
  end

  @doc """
  `value` as a share of `max` in percent, clamped to 0..100, for bar widths
  and heights. 0 when either isn't a positive number.

      iex> TalesForge.TeamPage.share(45, 90)
      50.0
      iex> TalesForge.TeamPage.share(nil, 90)
      0.0
  """
  @spec share(term(), term()) :: float()
  def share(value, max) when is_number(value) and is_number(max) and max > 0,
    do: (value / max * 100) |> max(0.0) |> min(100.0) |> Float.round(2)

  def share(_value, _max), do: 0.0

  defp parse_date(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_iso), do: :error

  # Fewest decimals (up to 6) that show the float exactly as stored.
  defp decimals_needed(value) do
    Enum.find(0..6, 6, &(Float.round(value, &1) == value))
  end

  defp delimit("-" <> digits), do: "-" <> delimit(digits)

  defp delimit(digits) do
    digits
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end
end
