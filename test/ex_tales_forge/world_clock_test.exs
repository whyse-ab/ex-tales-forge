defmodule TalesForge.Game.WorldClockTest do
  use ExUnit.Case, async: true

  alias TalesForge.Game.WorldClock

  test "tick constants match 15-minute tranches" do
    assert WorldClock.minutes_per_tick() == 15
    assert WorldClock.ticks_per_hour() == 4
    assert WorldClock.ticks_per_day() == 96
  end

  test "format/1 includes day and late afternoon for default start tick" do
    tick = WorldClock.default_start_tick()
    assert WorldClock.format(tick) =~ "Day 1"
    assert WorldClock.format(tick) =~ "late afternoon"
  end

  test "advance/2 increments tick and refreshes world_clock label" do
    world = %{"world_tick" => 36, "world_clock" => "old"}

    advanced = WorldClock.advance(world, 4)

    assert advanced["world_tick"] == 40
    assert advanced["world_clock"] == WorldClock.format(40)
  end

  test "parse_duration/1 reads numbered stays and defaults to one hour" do
    assert WorldClock.parse_duration("I wait") == 4
    assert WorldClock.parse_duration("I rest") == 4
    assert WorldClock.parse_duration("sleep") == 32
    assert WorldClock.parse_duration("wait 2 hours") == 8
    assert WorldClock.parse_duration("I spend three days drinking and gambling") == 288
    assert WorldClock.parse_duration("stay a week") == WorldClock.max_wait_ticks()
    assert WorldClock.parse_duration("wait 30 days") == WorldClock.max_wait_ticks()
  end
end
