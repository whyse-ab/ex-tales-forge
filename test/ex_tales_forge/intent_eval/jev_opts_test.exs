defmodule TalesForge.IntentEval.JevOptsTest do
  use ExUnit.Case, async: true

  alias TalesForge.IntentEval.JevOpts

  # The OS environment is never read here: each test passes its own getenv.
  defp env(map), do: &Map.get(map, &1)

  test "defaults match today's request when no flags or env are set" do
    assert JevOpts.from_flags([], env(%{})) == %JevOpts{
             skill_split: false,
             narration_chars: 800,
             player_chars: 600,
             last_actions: false,
             clarify_v2: false,
             runner_up: nil
           }
  end

  test "flags win over env vars" do
    env =
      env(%{
        "SKILL_SPLIT" => "on",
        "JEV_NARRATION_CHARS" => "1600",
        "JEV_PLAYER_CHARS" => "1200",
        "JEV_LAST_ACTIONS" => "on"
      })

    assert JevOpts.from_flags(
             [
               skill_split: false,
               narration_chars: 900,
               player_chars: 700,
               last_actions: false
             ],
             env
           ) == %JevOpts{
             skill_split: false,
             narration_chars: 900,
             player_chars: 700,
             last_actions: false,
             clarify_v2: false,
             runner_up: nil
           }
  end

  test "env supplies values when flags are absent" do
    env =
      env(%{
        "SKILL_SPLIT" => "on",
        "JEV_NARRATION_CHARS" => "1600",
        "JEV_PLAYER_CHARS" => "1200",
        "JEV_LAST_ACTIONS" => "true"
      })

    assert JevOpts.from_flags([], env) == %JevOpts{
             skill_split: true,
             narration_chars: 1600,
             player_chars: 1200,
             last_actions: true,
             clarify_v2: false,
             runner_up: nil
           }
  end

  test "boolean env follows on/true/1" do
    assert JevOpts.from_flags([], env(%{"SKILL_SPLIT" => "1"})).skill_split
    refute JevOpts.from_flags([], env(%{"SKILL_SPLIT" => "off"})).skill_split
    refute JevOpts.from_flags([], env(%{"JEV_LAST_ACTIONS" => "false"})).last_actions
  end

  test "a non-positive or garbage integer env is rejected" do
    assert_raise ArgumentError, fn ->
      JevOpts.from_flags([], env(%{"JEV_NARRATION_CHARS" => "nope"}))
    end

    assert_raise ArgumentError, fn ->
      JevOpts.from_flags([], env(%{"JEV_PLAYER_CHARS" => "0"}))
    end
  end

  test "JEV_CLARIFY_V2 and --runner-up are read, and the flag wins over env" do
    assert JevOpts.from_flags([], env(%{"JEV_CLARIFY_V2" => "on"})).clarify_v2
    refute JevOpts.from_flags([clarify_v2: false], env(%{"JEV_CLARIFY_V2" => "on"})).clarify_v2

    assert JevOpts.from_flags([runner_up: 0.4], env(%{})).runner_up == 0.4
    assert JevOpts.from_flags([], env(%{})).runner_up == nil
  end
end
