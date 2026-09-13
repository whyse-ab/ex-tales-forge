defmodule TalesForge.Game.ActionHandler do
  @moduledoc false

  # Core pure game logic. Ecto state only. No Ash.

  alias TalesForge.Game.Mechanics
  alias TalesForge.Game.Schemas.{HandlerResult, PlayerAction}
  alias TalesForge.Game.WorldClock

  @stub_actions ~w(use_item)a
  @inventory_actions ~w(pickup drop buy sell trade spend)a

  def resolve(%PlayerAction{} = player_action) do
    action = player_action.action
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
          skill: skill || "persuasion",
          target: action.target,
          notes: "Speak to #{action.target}."
        }

      action.action_type in [:observe, :interact, :combat, :other, :freeform] ->
        %HandlerResult{
          handler: "skill_check",
          skill: skill || "insight",
          target: action.target,
          notes: "Skill check for #{action.action_type}."
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

  def tick_delta(%{handler: "wait", state_hints: %{"ticks" => ticks}}) do
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
