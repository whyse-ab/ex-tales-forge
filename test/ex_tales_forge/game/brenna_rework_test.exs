defmodule TalesForge.Game.BrennaReworkTest do
  @moduledoc """
  Brenna rework (decision 2026-10-07, Fredrik via Case): a warm, chatty barkeep
  who enjoys running the tavern, without the default brush-off; a lead by
  turn 2; GM prose cleanup. The baseline variant keeps the old Brenna and
  prompts for the comparison arm.
  """
  use TalesForge.DataCase, async: false

  alias TalesForge.Game.{Pack, Prompts}
  alias TalesForge.GameSessions
  alias TalesForge.Jido
  alias TalesForge.NPC

  setup do
    on_exit(fn -> for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id) end)
    :ok
  end

  defp brenna(variant \\ "default") do
    "tin_valley" |> Pack.load(variant) |> Map.fetch!(:npcs) |> Enum.find(&(&1["id"] == "innkeep"))
  end

  test "Brenna is a warm, chatty host: higher extraversion and agreeableness, calmer" do
    brenna = brenna()
    traits = brenna["motivations"]["personality_traits"]

    assert traits["extraversion"] == 8
    assert traits["agreeableness"] == 8
    assert traits["neuroticism"] == 3
    assert brenna["personality"] =~ "Warm, chatty"
    assert brenna["personality"] =~ "enjoys running the tavern"
    assert brenna["motivations"]["mood"] == "cheerful"
    refute brenna["motivations"]["current_concern"]["focus"] =~ "strangers"
    assert brenna["maslow"] == "belonging"
    assert [%{"focus" => "a lively, safe common room"}] = brenna["concerns"]
    assert length(brenna["hooks"]) == 4
  end

  test "the baseline variant keeps the old, guarded Brenna and only her" do
    old = brenna("baseline")

    assert old["personality"] == "Practical, tired of guild politics, kind to paying guests."
    assert old["motivations"]["personality_traits"]["extraversion"] == 5
    assert old["motivations"]["current_concern"]["focus"] == "armed strangers on the valley road"
    refute Map.has_key?(old, "hooks")

    ids = fn variant ->
      "tin_valley"
      |> Pack.load(variant)
      |> Map.fetch!(:npcs)
      |> Enum.map(& &1["id"])
      |> Enum.sort()
    end

    assert ids.("baseline") == ids.("default")
  end

  test "a session's GM sections carry the variant's Brenna, with hooks only in the default" do
    {:ok, default} = GameSessions.create_session(%{adventure_id: "tin_valley"})

    {:ok, baseline} =
      GameSessions.create_session(%{adventure_id: "tin_valley", variant: "baseline"})

    new = NPC.format_gm_sections(default.id, ["innkeep"])
    assert new =~ ~s("hooks")
    assert new =~ "Osric Vane"
    assert new =~ ~s("mood": "cheerful")
    refute new =~ "armed strangers"

    old = NPC.format_gm_sections(baseline.id, ["innkeep"])
    refute old =~ ~s("hooks")
    assert old =~ "armed strangers on the valley road"
  end

  test "the GM prompt asks for a lead by turn 2 and clean, second-person prose" do
    gm = Prompts.gm_system()

    assert gm =~ "second turn at the latest"
    assert gm =~ ~s(An NPC's "hooks" are ready-made leads)
    assert gm =~ "do not default to suspicion, flat voices or brush-offs"
    assert gm =~ "Always second person"
    # Refined 2026-10-07 (no default echo; a rare deliberate echo is the exception).
    assert gm =~ "React, do not restate"
    assert gm =~ ~s("scarred oak")

    scene = Prompts.scene_system()
    assert scene =~ "a host greets a newcomer warmly"

    for prompt <- [Prompts.gm_system("baseline"), Prompts.scene_system("baseline")] do
      refute prompt =~ "scarred oak"
    end
  end
end
