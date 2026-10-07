defmodule TalesForgeWeb.TimeAgoTest do
  use ExUnit.Case, async: true

  alias TalesForgeWeb.TimeAgo

  doctest TalesForgeWeb.TimeAgo

  @now ~U[2026-10-07 12:00:00Z]

  defp ago(seconds), do: TimeAgo.relative(DateTime.add(@now, -seconds, :second), @now)

  test "bucket edges round down" do
    assert ago(0) == "a few seconds ago"
    assert ago(59) == "a few seconds ago"
    assert ago(60) == "a minute ago"
    assert ago(119) == "a minute ago"
    assert ago(120) == "2 minutes ago"
    assert ago(3_599) == "59 minutes ago"
    assert ago(3_600) == "an hour ago"
    assert ago(7_200) == "2 hours ago"
    assert ago(86_399) == "23 hours ago"
    assert ago(86_400) == "yesterday"
    assert ago(2 * 86_400 - 1) == "yesterday"
    assert ago(2 * 86_400) == "2 days ago"
    assert ago(29 * 86_400) == "29 days ago"
    assert ago(30 * 86_400) == "a month ago"
    assert ago(60 * 86_400) == "2 months ago"
    assert ago(365 * 86_400) == "a year ago"
    assert ago(730 * 86_400) == "2 years ago"
  end

  test "sub-second precision and the default now" do
    assert TimeAgo.relative(~U[2026-10-07 11:57:00.900000Z], @now) == "3 minutes ago"
    assert TimeAgo.relative(DateTime.utc_now()) == "a few seconds ago"
  end
end
