defmodule Mix.Tasks.Intent.EvalTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Intent.Eval

  # The OS environment is never read here: each test passes its own getenv.
  defp env(map), do: &Map.get(map, &1)

  @all %{
    "TYPESAFE_INTENT_PLAYTEST_API_KEY" => "playtest",
    "TYPESAFE_INTENT_API_KEY" => "intent",
    "TYPESAFE_API_KEY" => "jev"
  }

  test "--api-key wins over every env var" do
    assert Eval.api_key([api_key: "flag"], env(@all)) == {"flag", "--api-key"}
  end

  test "the playtest intent key comes before the prod intent key" do
    assert Eval.api_key([], env(@all)) == {"playtest", "TYPESAFE_INTENT_PLAYTEST_API_KEY"}
  end

  test "falls back to TYPESAFE_INTENT_API_KEY, then TYPESAFE_API_KEY" do
    no_playtest = Map.delete(@all, "TYPESAFE_INTENT_PLAYTEST_API_KEY")
    assert Eval.api_key([], env(no_playtest)) == {"intent", "TYPESAFE_INTENT_API_KEY"}

    only_jev = %{"TYPESAFE_API_KEY" => "jev"}
    assert Eval.api_key([], env(only_jev)) == {"jev", "TYPESAFE_API_KEY"}
  end

  test "blank values are skipped and no key gives {nil, \"none\"}" do
    blank = %{"TYPESAFE_INTENT_PLAYTEST_API_KEY" => "  ", "TYPESAFE_INTENT_API_KEY" => "intent"}
    assert Eval.api_key([api_key: ""], env(blank)) == {"intent", "TYPESAFE_INTENT_API_KEY"}
    assert Eval.api_key([], env(%{})) == {nil, "none"}
  end
end
