defmodule TalesForge.Survey.CacheTest do
  use ExUnit.Case, async: false

  alias TalesForge.Survey.Cache

  setup do
    on_exit(&Cache.clear/0)
  end

  test "fresh, stale and missing entries" do
    assert Cache.get(:cache_test) == :miss
    assert Cache.put(:cache_test, 1, 60_000) == 1
    assert Cache.get(:cache_test) == {:fresh, 1}

    Cache.put(:cache_test, 2, 0)
    assert Cache.get(:cache_test) == {:stale, 2}

    assert Cache.delete(:cache_test) == :ok
    assert Cache.get(:cache_test) == :miss
  end
end
