defmodule TalesForge.Playtest.RunMetaTest do
  # Touches process-wide env vars (GIT_SHA, NPC_REACTIONS, WORLD_AGENTS, models).
  use ExUnit.Case, async: false

  alias TalesForge.Playtest.{JevScorer, RunMeta}

  @env ~w(GIT_SHA NPC_REACTIONS WORLD_AGENTS TIER1_MODEL TIER2_MODEL)

  setup do
    saved = Map.new(@env, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    Enum.each(@env, &System.delete_env/1)
    :ok
  end

  doctest RunMeta

  test "git_sha treats a missing, blank or unknown build arg as unknown" do
    assert RunMeta.git_sha() == nil
    System.put_env("GIT_SHA", "unknown")
    assert RunMeta.git_sha() == nil
    System.put_env("GIT_SHA", "  ")
    assert RunMeta.git_sha() == nil
    System.put_env("GIT_SHA", " 00c370d \n")
    assert RunMeta.git_sha() == "00c370d"
  end

  test "flags record the switches, the session variant, the models and the rubric" do
    System.put_env("NPC_REACTIONS", "on")
    System.put_env("TIER2_MODEL", "gm-model")

    flags = RunMeta.flags("hawk", %{"variant" => "baseline"})

    assert flags["npc_reactions"] == "on"
    assert flags["world_agents"] == "off"
    assert flags["variant"] == "baseline"
    assert flags["gm_model"] == "gm-model"
    assert flags["intent_model"] == TalesForge.Config.xai_model()
    assert flags["jev_rubric"] == JevScorer.rubric_version("hawk")
    assert RunMeta.flags("paul")["variant"] == "default"
    assert RunMeta.flags("nobody")["jev_rubric"] == nil
  end

  test "flags never carry secrets" do
    System.put_env("XAI_API_KEY_FOR_TEST", "secret-value")
    on_exit(fn -> System.delete_env("XAI_API_KEY_FOR_TEST") end)

    refute RunMeta.flags("paul") |> Map.values() |> Enum.any?(&(&1 == "secret-value"))
    refute RunMeta.flags("paul") |> Map.keys() |> Enum.any?(&(&1 =~ ~r/key|token|secret/i))
  end

  test "short_sha and commit_url" do
    assert RunMeta.short_sha(nil) == nil
    assert RunMeta.short_sha("00c370d1a2b3") == "00c370d"
    assert RunMeta.commit_url(nil) == nil
    assert RunMeta.commit_url("abc") == "https://github.com/whyse-ab/ex-tales-forge/commit/abc"
  end
end
