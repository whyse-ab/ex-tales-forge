defmodule TalesForge.Game.ActionHandler do
  @moduledoc false

  # Core pure game logic. Ecto state only.
  #
  # Roll rule (decision 2026-10-07, from Fredrik via Case): roll only when the
  # outcome is uncertain and failing matters. Speak, observe, interact, other
  # and freeform take the skill the intent step chose, and no skill means no
  # check. Combat always rolls (melee_combat unless named). The baseline variant
  # keeps the old defaults: persuasion for speak, insight for everything else.

  alias TalesForge.Game.Mechanics
  alias TalesForge.Game.Schemas.{HandlerResult, PlayerAction}
  alias TalesForge.Game.Variant
  alias TalesForge.Game.WorldClock

  @stub_actions ~w(use_item)a
  @inventory_actions ~w(pickup drop buy sell trade spend)a

  def resolve(%PlayerAction{} = player_action, variant \\ "default") do
    action = player_action.action
    baseline? = Variant.baseline?(%{"variant" => variant})
    skill = action.parameters |> Map.get("skill") |> Mechanics.normalize_skill_name()

    cond do
      action.action_type in @stub_actions ->
        %HandlerResult{
          handler: "freeform",
          skill: skill,
          target: action.target,
          notes: "Stub handler for #{action.action_type}; narrated as freeform."
        }

      action.action_type in @inventory_actions ->
        %HandlerResult{
          handler: "inventory",
          target: action.target,
          notes: "Inventory #{action.action_type}.",
          state_hints: %{
            "action_type" => Atom.to_string(action.action_type),
            "parameters" => action.parameters
          }
        }

      action.action_type == :wait ->
        ticks = wait_ticks(player_action)

        %HandlerResult{
          handler: "wait",
          target: action.target,
          notes: "Wait #{ticks} ticks.",
          state_hints: %{"ticks" => ticks}
        }

      action.action_type == :train ->
        ticks = wait_ticks(player_action)

        %HandlerResult{
          handler: "train",
          target: action.target,
          notes: "Train #{ticks} ticks.",
          state_hints: %{"ticks" => ticks}
        }

      action.action_type == :move ->
        %HandlerResult{
          handler: "move",
          skill: skill,
          target: action.target,
          notes: "Move to #{action.target}.",
          state_hints: %{"location_id" => action.target}
        }

      action.action_type == :speak ->
        %HandlerResult{
          handler: "speak",
          skill: if(baseline?, do: skill || "persuasion", else: skill),
          target: action.target,
          notes: "Speak to #{action.target}."
        }

      action.action_type == :combat ->
        %HandlerResult{
          handler: "skill_check",
          skill: skill || if(baseline?, do: "insight", else: "melee_combat"),
          target: action.target,
          notes: "Skill check for combat."
        }

      action.action_type in [:observe, :interact, :other, :freeform] and baseline? ->
        %HandlerResult{
          handler: "skill_check",
          skill: skill || "insight",
          target: action.target,
          notes: "Skill check for #{action.action_type}."
        }

      action.action_type in [:observe, :interact, :other, :freeform] and is_binary(skill) ->
        %HandlerResult{
          handler: "skill_check",
          skill: skill,
          target: action.target,
          notes: "Skill check for #{action.action_type}."
        }

      action.action_type in [:observe, :interact, :other, :freeform] ->
        %HandlerResult{
          handler: "narrate",
          target: action.target,
          notes: "No check: ordinary #{action.action_type}, nothing uncertain at stake."
        }

      true ->
        %HandlerResult{
          handler: "freeform",
          skill: skill,
          target: action.target,
          notes: "Unhandled action_type #{action.action_type}; freeform."
        }
    end
  end

  def tick_delta(%{handler: handler, state_hints: %{"ticks" => ticks}})
      when handler in ["wait", "train"] do
    WorldClock.clamp_wait(ticks)
  end

  def tick_delta(_), do: 1

  defp wait_ticks(%PlayerAction{} = player_action) do
    case player_action.action.parameters do
      %{"ticks" => ticks} -> WorldClock.clamp_wait(ticks)
      _ -> WorldClock.parse_duration(player_action.overall_intent || "")
    end
  end
end
