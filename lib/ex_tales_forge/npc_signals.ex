defmodule TalesForge.NPCSignals do
  @moduledoc """
  Emits Jido signals to present NPC agents after turn processing.
  """

  require Logger

  alias Jido.AgentServer
  alias Jido.Signal
  alias TalesForge.Game.ActionHandler
  alias TalesForge.NPCRegistry

  def emit_turn_signals(session_id, world_state, handler, raw_action) do
    present_npcs = Map.get(world_state, "present_npcs", [])
    world_tick = Map.get(world_state, "world_tick", 0)
    delta = ActionHandler.tick_delta(handler)

    emit_time_passed(session_id, world_tick, delta, present_npcs)

    if speak_to_npc?(handler) do
      emit_player_talked(session_id, handler.target, raw_action, world_tick)
    end

    unless wait?(handler) do
      emit_overhear(session_id, world_tick, present_npcs, handler, raw_action)
    end

    :ok
  end

  def emit_time_passed(session_id, world_tick, delta_ticks, present_npc_ids) do
    payload = %{
      "session_id" => session_id,
      "world_tick" => world_tick,
      "delta_ticks" => delta_ticks
    }

    Enum.each(present_npc_ids, fn npc_id ->
      deliver(session_id, npc_id, "world.time.passed", payload)
    end)
  end

  def emit_player_talked(session_id, npc_id, player_text, world_tick) do
    payload = %{
      "session_id" => session_id,
      "npc_id" => npc_id,
      "player_text" => player_text,
      "world_tick" => world_tick
    }

    deliver(session_id, npc_id, "player.talked_to", payload)
  end

  defp deliver(session_id, npc_id, type, payload) do
    aid = NPCRegistry.agent_id(session_id, npc_id)
    signal = Signal.new!(type, payload, source: "/game/turn_processor")

    case TalesForge.Jido.whereis(aid) do
      nil ->
        :ok

      pid ->
        case AgentServer.call(pid, signal) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.debug(
              "npc signal undelivered session=#{session_id} npc=#{npc_id} type=#{type} reason=#{inspect(reason)}"
            )
        end
    end
  end

  defp emit_overhear(session_id, world_tick, present_npcs, handler, raw_action) do
    trimmed = String.trim(raw_action || "")

    if trimmed != "" do
      speak_target = if speak_to_npc?(handler), do: handler.target, else: nil

      present_npcs
      |> Enum.reject(&(&1 == speak_target))
      |> Enum.each(fn npc_id ->
        deliver(
          session_id,
          npc_id,
          "conversation.message",
          %{
            "session_id" => session_id,
            "speaker" => "player",
            "message" => trimmed,
            "world_tick" => world_tick
          }
        )
      end)
    end
  end

  defp speak_to_npc?(%{handler: "speak", target: target}) when is_binary(target), do: true
  defp speak_to_npc?(_), do: false

  defp wait?(%{handler: "wait"}), do: true
  defp wait?(_), do: false
end
