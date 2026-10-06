defmodule TalesForge.PubSub.GameSession do
  @moduledoc """
  Phoenix PubSub bridge for live game session updates.
  """

  @pubsub TalesForge.PubSub

  def topic(session_id), do: "game_session:#{session_id}"

  def subscribe(session_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(session_id))
  end

  def broadcast(session_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, topic(session_id), event)
  end

  @doc "Reason for `:turn_failed` / `:scene_failed`: spend caps stay matchable, the rest is text."
  def failure_reason({:spend_cap, _kind} = reason), do: reason
  def failure_reason(reason), do: inspect(reason)
end
