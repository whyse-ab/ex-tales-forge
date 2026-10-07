defmodule TalesForgeWeb.TimeAgo do
  @moduledoc """
  Human-readable times for the admin: how long ago something happened
  ("3 minutes ago", "yesterday") and the matching absolute time on
  Europe/Stockholm wall-clock time, for a tooltip or secondary text.

  Pure functions: pass `now` explicitly to get a deterministic result (tests,
  or one `now` for a whole table so every row agrees).
  """

  @zone "Europe/Stockholm"

  @minute 60
  @hour 60 * @minute
  @day 24 * @hour
  @month 30 * @day
  @year 365 * @day

  @doc """
  How long before `now` the instant `then` was, in words.

  Buckets use the elapsed time, rounded down: under a minute is "a few seconds
  ago", then minutes, hours, "yesterday" (24 to 48 hours), days, months of 30
  days and years of 365 days. A `then` after `now` (clock skew) reads as "a few
  seconds ago".

  ## Examples

      iex> now = ~U[2026-10-07 12:00:00Z]
      iex> TalesForgeWeb.TimeAgo.relative(~U[2026-10-07 11:59:50Z], now)
      "a few seconds ago"
      iex> TalesForgeWeb.TimeAgo.relative(~U[2026-10-07 11:58:30Z], now)
      "a minute ago"
      iex> TalesForgeWeb.TimeAgo.relative(~U[2026-10-07 11:57:00Z], now)
      "3 minutes ago"
      iex> TalesForgeWeb.TimeAgo.relative(~U[2026-10-07 10:59:00Z], now)
      "an hour ago"
      iex> TalesForgeWeb.TimeAgo.relative(~U[2026-10-07 09:30:00Z], now)
      "2 hours ago"
      iex> TalesForgeWeb.TimeAgo.relative(~U[2026-10-06 08:00:00Z], now)
      "yesterday"
      iex> TalesForgeWeb.TimeAgo.relative(~U[2026-10-03 12:00:00Z], now)
      "4 days ago"
      iex> TalesForgeWeb.TimeAgo.relative(~U[2026-08-20 12:00:00Z], now)
      "a month ago"
      iex> TalesForgeWeb.TimeAgo.relative(~U[2026-05-07 12:00:00Z], now)
      "5 months ago"
      iex> TalesForgeWeb.TimeAgo.relative(~U[2025-09-01 12:00:00Z], now)
      "a year ago"
      iex> TalesForgeWeb.TimeAgo.relative(~U[2023-10-07 12:00:00Z], now)
      "3 years ago"
      iex> TalesForgeWeb.TimeAgo.relative(~U[2026-10-07 12:00:05Z], now)
      "a few seconds ago"
  """
  @spec relative(DateTime.t(), DateTime.t()) :: String.t()
  def relative(%DateTime{} = then, %DateTime{} = now \\ DateTime.utc_now()) do
    now |> DateTime.diff(then, :second) |> max(0) |> words()
  end

  defp words(s) when s < @minute, do: "a few seconds ago"
  defp words(s) when s < 2 * @minute, do: "a minute ago"
  defp words(s) when s < @hour, do: "#{div(s, @minute)} minutes ago"
  defp words(s) when s < 2 * @hour, do: "an hour ago"
  defp words(s) when s < @day, do: "#{div(s, @hour)} hours ago"
  defp words(s) when s < 2 * @day, do: "yesterday"
  defp words(s) when s < @month, do: "#{div(s, @day)} days ago"
  defp words(s) when s < 2 * @month, do: "a month ago"
  defp words(s) when s < @year, do: "#{div(s, @month)} months ago"
  defp words(s) when s < 2 * @year, do: "a year ago"
  defp words(s), do: "#{div(s, @year)} years ago"

  @doc """
  `dt` on Europe/Stockholm wall-clock time, with the zone abbreviation
  (CET in winter, CEST in summer), e.g. for a `title` tooltip.

  ## Examples

      iex> TalesForgeWeb.TimeAgo.stockholm(~U[2026-10-06 15:00:00Z])
      "2026-10-06 17:00 CEST"
      iex> TalesForgeWeb.TimeAgo.stockholm(~U[2026-12-24 15:00:00Z])
      "2026-12-24 16:00 CET"
      iex> TalesForgeWeb.TimeAgo.stockholm(~U[2026-12-24 15:00:00Z], "%d %b %H:%M")
      "24 Dec 16:00"
  """
  @spec stockholm(DateTime.t(), String.t()) :: String.t()
  def stockholm(%DateTime{} = dt, format \\ "%Y-%m-%d %H:%M %Z") do
    dt
    |> DateTime.shift_zone!(@zone, TimeZoneInfo.TimeZoneDatabase)
    |> Calendar.strftime(format)
  end
end
