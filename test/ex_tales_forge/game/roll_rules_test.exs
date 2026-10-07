defmodule TalesForge.Game.RollRulesTest do
  @moduledoc """
  Roll rule (decision 2026-10-07, from Fredrik via Case): no skill roll on
  ordinary talk; roll only when the outcome is uncertain and failing matters.
  A failed read means learning nothing extra, never a colder NPC. The baseline
  variant keeps the old behaviour for the comparison arm.
  """
  use TalesForge.DataCase, async: false

  alias TalesForge.Game.{ActionHandler, Context, Intent, Mechanics, NpcReactions, Prompts}
  alias TalesForge.Game.Schemas.{IntentExtraction, MechanicalResolution, SingleAction}
  alias TalesForge.GameSessions
  alias TalesForge.Jido

  doctest TalesForge.Game.Variant
  doctest Mechanics, only: [infer_check_skill: 1, untrained_floor: 1]

  setup do
    on_exit(fn -> for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id) end)
    :ok
  end

  defp session(variant) do
    {:ok, session} =
      GameSessions.create_session(%{name: "Rolls", adventure_id: "tin_valley", variant: variant})

    session
  end

  # The resolution a turn would get: intent heuristic → handler → server roll.
  defp resolve(session, text) do
    context = Context.build_intent_context(session)
    action = text |> Intent.heuristic_intent(context) |> Intent.validate_player_action(context)
    handler = ActionHandler.resolve(action, context["variant"])
    character = session.world_state["character"]
    {_character, rolled} = Mechanics.apply_server_mechanics(character, action, handler)
    {action, handler, rolled}
  end

  @ordinary [
    "A tankard of your finest ale and a seat by the fire, if you please.",
    "I ask Brenna what the miners talk about these days",
    "Good evening! Quite the crowd tonight.",
    "I look around the common room",
    "I sit down and eat my stew"
  ]

  test "ordinary talk and everyday actions get no roll" do
    session = session("default")

    for text <- @ordinary do
      {_action, handler, rolled} = resolve(session, text)
      assert handler.skill == nil, "#{text} got skill #{inspect(handler.skill)}"
      assert %MechanicalResolution{outcome: "none", roll: nil} = rolled
    end
  end

  test "uncertain actions with stakes still roll the matching skill" do
    session = session("default")

    for {text, skill} <- [
          {"I try to convince Brenna to knock a copper off the room", "persuasion"},
          {"I search the loose floorboard by the hearth", "insight"},
          {"I lie and say the Guild sent me", "deception"},
          {"I sneak past the miners to the back door", "stealth"},
          {"I attack the guild man", "melee_combat"}
        ] do
      {_action, handler, rolled} = resolve(session, text)
      assert handler.skill == skill, text
      assert rolled.skill == skill
      assert is_integer(rolled.roll)
    end
  end

  test "the baseline variant keeps the old defaults: Insight or Persuasion on everything" do
    session = session("baseline")

    {_action, handler, rolled} = resolve(session, "I look around the common room")
    assert handler.skill == "insight"
    assert rolled.skill == "insight" and is_integer(rolled.roll)

    {_action, handler, _rolled} = resolve(session, "Good evening! Quite the crowd tonight.")
    assert handler.skill == "insight"

    {_action, handler, _rolled} = resolve(session, "I ask Brenna about the road")
    assert handler.skill == "persuasion"
  end

  test "a Tier 1 action without a skill is valid and means no check (baseline: required)" do
    extraction = %IntentExtraction{
      overall_intent: "greet the innkeeper",
      actions: [%SingleAction{action_type: :speak, target: "innkeep", parameters: %{}}],
      primary_index: 0,
      confidence: 0.95
    }

    action = Intent.validate_player_action(extraction, %{"variant" => "default"})
    assert %{handler: "speak", skill: nil} = ActionHandler.resolve(action)

    assert_raise ArgumentError, fn ->
      Intent.validate_player_action(extraction, %{"variant" => "baseline"})
    end
  end

  test "combat without a named skill rolls melee, observe without one only narrates" do
    combat = player_action(:combat)
    assert %{skill: "melee_combat"} = ActionHandler.resolve(combat)
    assert %{skill: "insight"} = ActionHandler.resolve(combat, "baseline")

    observe = player_action(:observe)
    assert %{handler: "narrate", skill: nil} = ActionHandler.resolve(observe)

    assert %{handler: "skill_check", skill: "insight"} =
             ActionHandler.resolve(observe, "baseline")
  end

  test "an NPC never sees a failed read; she does see a failed lie" do
    failed_read = %MechanicalResolution{skill: "insight", outcome: "failure", roll: 17}
    failed_lie = %MechanicalResolution{skill: "deception", outcome: "failure", roll: 17}

    assert NpcReactions.visible_outcome(failed_read, %{}) == nil
    assert NpcReactions.visible_outcome(failed_lie, %{}) == failed_lie
    assert NpcReactions.visible_outcome(failed_read, %{"variant" => "baseline"}) == failed_read
  end

  test "the GM prompt says a failed check means learning nothing extra, not a colder NPC" do
    gm = Prompts.gm_system()
    assert gm =~ "learns nothing extra"
    assert gm =~ "never makes an NPC colder"
    assert gm =~ "Outcome none means no check was needed"

    intent = Prompts.intent_system()
    assert intent =~ "Ordinary talk and everyday actions get no skill"
  end

  test "the baseline variant reads the pre-rework prompt files" do
    baseline_dir = Path.join(:code.priv_dir(:ex_tales_forge), "prompts/variants/baseline")

    assert Prompts.gm_system("baseline") == File.read!(Path.join(baseline_dir, "gm_system.txt"))
    refute Prompts.gm_system("baseline") =~ "learns nothing extra"

    assert Prompts.intent_system("baseline") ==
             File.read!(Path.join(baseline_dir, "intent_system.txt"))

    # No override file: the shared one.
    assert Prompts.narrator_system("baseline") == Prompts.narrator_system()
  end

  test "sessions store a non-default variant; unknown variants are refused" do
    assert session("baseline").world_state["variant"] == "baseline"
    refute Map.has_key?(session("default").world_state, "variant")

    assert GameSessions.create_session(%{adventure_id: "tin_valley", variant: "nope"}) ==
             {:error, :unknown_variant}
  end

  test "GAME_VARIANT sets the variant of new sessions" do
    System.put_env("GAME_VARIANT", "baseline")
    on_exit(fn -> System.delete_env("GAME_VARIANT") end)

    {:ok, session} = GameSessions.create_session(%{adventure_id: "tin_valley"})
    assert session.world_state["variant"] == "baseline"
  end

  defp player_action(type) do
    %TalesForge.Game.Schemas.PlayerAction{
      overall_intent: "something",
      action: %SingleAction{action_type: type, target: nil, parameters: %{}}
    }
  end
end
