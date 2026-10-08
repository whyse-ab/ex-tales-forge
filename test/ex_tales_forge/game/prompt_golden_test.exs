defmodule TalesForge.Game.PromptGoldenTest do
  @moduledoc """
  Byte-identical prompts for a fixed session of each adventure.

  The Character plan (tales-forge-docs `docs/plan-unify-character.md`) moves
  player characters and NPCs into one `characters` table in phases. Until a
  phase deliberately changes what the models see, every prompt must stay
  exactly the same: the intent context, the opening-scene request and the GM
  turn messages (narrator, rules, task, session-stable and per-turn parts),
  plus the player character's sheet in `world_state`. The default-variant
  files also hold the intent call's system prompt and schema.

  The golden files in `test/fixtures/prompts/` are one per adventure and
  behaviour variant (`TalesForge.Game.Variant`): `<adventure>.txt` for the
  default variant, `<adventure>.baseline.txt` for the baseline. The baseline
  files are the pre-rework prompts byte for byte (written from main before
  phase 1) and must not change while the baseline arm exists. Session ids,
  other UUIDs and timestamps are normalised. To regenerate after an intended
  prompt change, run
  `UPDATE_PROMPT_GOLDEN=1 mix test test/ex_tales_forge/game/prompt_golden_test.exs`
  and review the diff.
  """
  use TalesForge.DataCase, async: false

  alias TalesForge.Game.Context
  alias TalesForge.Game.Prompts
  alias TalesForge.Game.Schemas.{HandlerResult, MechanicalResolution, PlayerAction, SingleAction}
  alias TalesForge.GameSessions
  alias TalesForge.Game.Variant
  alias TalesForge.Jido
  alias TalesForge.LLM
  alias TalesForge.NPC

  @dir Path.expand("../../fixtures/prompts", __DIR__)

  setup do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    :ok
  end

  for adventure <- ~w(crossroads_ledger tin_valley), variant <- ~w(default baseline) do
    test "#{adventure} (#{variant}): prompts are byte-identical to the golden file" do
      check_golden(unquote(adventure), unquote(variant))
    end
  end

  defp check_golden(adventure, variant) do
    {:ok, session} =
      GameSessions.create_session(%{name: "Golden", adventure_id: adventure, variant: variant})

    actual = render(session)
    suffix = if variant == "default", do: "", else: ".#{variant}"
    path = Path.join(@dir, "#{adventure}#{suffix}.txt")

    if System.get_env("UPDATE_PROMPT_GOLDEN") in ~w(1 true) do
      File.mkdir_p!(@dir)
      File.write!(path, actual)
    end

    expected = File.read!(path)

    assert actual == expected,
           "prompts for #{adventure} changed; diff #{path} against a fresh render " <>
             "(UPDATE_PROMPT_GOLDEN=1 rewrites it)"
  end

  defp render(session) do
    context = Context.build_gm_context(session)
    present = Map.get(context.intent_context, "present_npcs", [])

    sections =
      [
        {"world_state.character", Jason.encode!(session.world_state["character"], pretty: true)},
        {"intent context",
         session |> Context.build_intent_context() |> Context.format_intent_context()},
        {"npc gm sections", NPC.format_gm_sections(session.id, present)},
        {"scene messages", messages(Prompts.scene_messages(context))},
        {"gm turn 1", messages(gm_messages(context, 1, "look around"))},
        {"gm turn 4", messages(gm_messages(context, 4, "ask about the road"))}
      ] ++ intent_request(Variant.of(session.world_state))

    sections
    |> Enum.map_join("\n", fn {title, body} -> "===== #{title} =====\n#{body}\n" end)
    |> normalise(session.id)
  end

  # The intent call's static system prompt and schema. Default variant only:
  # the baseline files predate this section and stay byte-identical (the
  # baseline intent prompt and schema are frozen too, see PlayerQuoteTest).
  defp intent_request("baseline"), do: []

  defp intent_request(variant) do
    [
      {"intent system", Prompts.intent_system(variant)},
      {"intent schema", Jason.encode!(LLM.intent_schema(variant), pretty: true)}
    ]
  end

  defp gm_messages(context, turn_number, text) do
    player_action = %PlayerAction{
      overall_intent: text,
      action: %SingleAction{action_type: :observe, target: nil}
    }

    Prompts.gm_messages(
      context,
      %MechanicalResolution{skill: "insight", roll: 14, outcome: "success"},
      player_action,
      %HandlerResult{handler: "observe", skill: "insight"},
      turn_number
    )
  end

  defp messages(list) do
    Enum.map_join(list, "\n", fn m -> "--- #{m.role} ---\n#{m.content}" end)
  end

  defp normalise(text, session_id) do
    text
    |> String.replace(session_id, "<SESSION>")
    |> String.replace(~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/, "<UUID>")
    |> String.replace(~r/\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d+)?Z?/, "<TS>")
  end
end
