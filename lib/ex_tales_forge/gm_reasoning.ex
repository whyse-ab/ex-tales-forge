defmodule TalesForge.GMReasoning do
  @moduledoc """
  The GM's hidden notes and raw JSON reply for each turn, stored as a
  player-unaware `gm_reasoning` session event for session reports. Never shown
  to the player, never fed back into a prompt.
  """

  require Logger

  import Ecto.Query

  alias TalesForge.Game.Schemas.GMStructuredResponse
  alias TalesForge.Repo
  alias TalesForge.Schemas.SessionEvent

  @kind "gm_reasoning"

  @doc "Adds a `:gm_reasoning` step after `:turn`. A failed insert is logged and never aborts the turn."
  def multi_insert(multi, session_id, tick, %GMStructuredResponse{} = gm_result) do
    Ecto.Multi.run(multi, :gm_reasoning, fn _repo, %{turn: turn} ->
      {:ok, insert(session_id, tick, turn, gm_result)}
    end)
  end

  @doc "A session's reasoning events, ordered by turn."
  def list_for_session(session_id) do
    SessionEvent
    |> where([e], e.game_session_id == ^session_id and e.kind == @kind)
    |> order_by([e], asc: fragment("(?->>'turn_number')::int", e.payload), asc: e.inserted_at)
    |> Repo.all()
  end

  defp insert(session_id, tick, turn, gm_result) do
    %SessionEvent{}
    |> SessionEvent.changeset(%{
      game_session_id: session_id,
      kind: @kind,
      actor: "gm",
      player_aware: false,
      tick: tick || 0,
      payload: %{
        "turn_id" => turn.id,
        "turn_number" => turn.turn_number,
        "gm_notes" => gm_result.gm_notes,
        "gm_reply" => gm_result.raw
      }
    })
    |> Repo.insert_isolated()
    |> case do
      {:ok, event} ->
        event

      {:error, changeset} ->
        Logger.warning(
          "gm reasoning not stored session=#{session_id} errors=#{inspect(changeset.errors)}"
        )

        nil
    end
  rescue
    e ->
      Logger.warning(
        "gm reasoning not stored session=#{session_id} error=#{Exception.message(e)}"
      )

      nil
  end
end
