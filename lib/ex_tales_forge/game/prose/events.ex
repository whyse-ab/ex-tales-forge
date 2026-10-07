defmodule TalesForge.Game.Prose.Events do
  @moduledoc "Player-unaware session events written by the prose-mode follow-ups."

  import Ecto.Query

  alias TalesForge.Repo
  alias TalesForge.Schemas.SessionEvent

  @doc "Payload of the newest event of `kind`, or nil."
  def latest(session_id, kind) do
    SessionEvent
    |> where([e], e.game_session_id == ^session_id and e.kind == ^kind)
    |> order_by([e], desc: e.inserted_at)
    |> limit(1)
    |> select([e], e.payload)
    |> Repo.one()
  end

  @doc "Payloads of all events of `kind`, oldest first."
  def list(session_id, kind) do
    SessionEvent
    |> where([e], e.game_session_id == ^session_id and e.kind == ^kind)
    |> order_by([e], asc: e.inserted_at)
    |> select([e], e.payload)
    |> Repo.all()
  end

  @doc "Inserts one event; failures are returned, never raised."
  def insert(session_id, kind, actor, payload) do
    %SessionEvent{}
    |> SessionEvent.changeset(%{
      game_session_id: session_id,
      kind: kind,
      actor: actor,
      player_aware: false,
      tick: 0,
      payload: payload
    })
    |> Repo.insert_isolated()
  end
end
