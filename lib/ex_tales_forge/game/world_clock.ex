defmodule TalesForge.Game.WorldClock do
  @moduledoc """
  In-world time via discrete ticks.

  - 1 tick ≈ 15 minutes
  - 4 ticks ≈ 1 hour
  - 96 ticks ≈ 1 day (~100 is a fair round-number approximation)
  """

  @minutes_per_tick 15
  @ticks_per_hour 4
  @ticks_per_day 96
  @max_wait_days 7
  @word_counts %{
    "a" => 1,
    "an" => 1,
    "one" => 1,
    "two" => 2,
    "three" => 3,
    "four" => 4,
    "five" => 5,
    "six" => 6,
    "seven" => 7,
    "eight" => 8,
    "nine" => 9,
    "ten" => 10
  }

  def minutes_per_tick, do: @minutes_per_tick
  def ticks_per_hour, do: @ticks_per_hour
  def ticks_per_day, do: @ticks_per_day
  def max_wait_ticks, do: @ticks_per_day * @max_wait_days

  @default_start_tick 36

  def default_start_tick, do: @default_start_tick

  def advance(world_state, delta \\ 1) when is_map(world_state) and is_integer(delta) do
    tick = Map.get(world_state, "world_tick", @default_start_tick) + delta

    world_state
    |> Map.put("world_tick", tick)
    |> Map.put("world_clock", format(tick))
  end

  def format(tick) when is_integer(tick) and tick >= 0 do
    day = div(tick, @ticks_per_day) + 1
    "Day #{day} · #{time_of_day(rem(tick, @ticks_per_day))}"
  end

  @doc """
  Clamp a wait to at least 1 tick and at most 7 in-game days.
  Time only advances from a table action — never while AFK.
  """
  def clamp_wait(n) when is_integer(n) and n >= 1, do: min(n, max_wait_ticks())
  def clamp_wait(_), do: @ticks_per_hour

  @doc """
  Parse a player phrase into wait ticks.

  Bare "wait" / "rest" is one hour. "sleep" is eight hours.
  Numbered durations ("three days", "2 hours") win when present.
  """
  def parse_duration(text) when is_binary(text) do
    lowered = String.downcase(text)

    cond do
      match =
          Regex.run(
            ~r/\b(a|an|one|two|three|four|five|six|seven|eight|nine|ten|\d+)\s+(hours?|days?|nights?|weeks?)\b/,
            lowered
          ) ->
        [_whole, count, unit] = match
        clamp_wait(count_value(count) * unit_ticks(unit))

      Regex.match?(~r/\b(sleep|nap|turn in)\b/, lowered) ->
        clamp_wait(@ticks_per_hour * 8)

      true ->
        @ticks_per_hour
    end
  end

  defp count_value(word) do
    Map.get(@word_counts, word) ||
      case Integer.parse(word) do
        {n, _} when n > 0 -> n
        _ -> 1
      end
  end

  defp unit_ticks(unit) do
    cond do
      String.starts_with?(unit, "hour") -> @ticks_per_hour
      String.starts_with?(unit, "week") -> @ticks_per_day * 7
      true -> @ticks_per_day
    end
  end

  defp time_of_day(slot) when slot in 0..3, do: "deep night"
  defp time_of_day(slot) when slot in 4..7, do: "dawn"
  defp time_of_day(slot) when slot in 8..15, do: "morning"
  defp time_of_day(slot) when slot in 16..23, do: "midday"
  defp time_of_day(slot) when slot in 24..31, do: "afternoon"
  defp time_of_day(slot) when slot in 32..39, do: "late afternoon"
  defp time_of_day(slot) when slot in 40..47, do: "dusk"
  defp time_of_day(slot) when slot in 48..55, do: "evening"
  defp time_of_day(slot) when slot in 56..63, do: "night"
  defp time_of_day(slot) when slot in 64..71, do: "late night"
  defp time_of_day(slot) when slot in 72..79, do: "witching hour"
  defp time_of_day(slot) when slot in 80..87, do: "pre-dawn"
  defp time_of_day(_), do: "deep night"
end
