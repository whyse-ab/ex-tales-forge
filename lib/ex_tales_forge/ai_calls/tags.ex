defmodule TalesForge.AICalls.Tags do
  @moduledoc """
  World/module and game-system tags for `ai_calls` rows.

  - `adventure_id`: the adventure pack the session plays (`world_state["adventure_id"]`,
    e.g. `tin_valley`), the "module" layer.
  - `game_system`: the rules system. Every pack uses the built-in 1d20
    roll-under skill system today (`#{inspect("skill_d20")}`); a session whose
    world_state carries `"game_system"` overrides it.

  Calls without a session (or with an unknown one) get nil tags.
  """

  import Ecto.Query

  alias TalesForge.Repo
  alias TalesForge.Schemas.GameSession

  @default_game_system "skill_d20"

  @empty %{adventure_id: nil, game_system: nil}

  def default_game_system, do: @default_game_system

  @doc "Tags from a session's world_state map."
  def for_world(%{} = world) do
    case world["adventure_id"] do
      id when is_binary(id) and id != "" ->
        %{adventure_id: id, game_system: world["game_system"] || @default_game_system}

      _ ->
        @empty
    end
  end

  def for_world(_world), do: @empty

  @doc "Tags for a session id: one primary-key read of two world_state keys."
  def for_session(session_id) when is_binary(session_id) do
    with {:ok, id} <- Ecto.UUID.cast(session_id),
         {adventure_id, game_system} <-
           Repo.one(
             from s in GameSession,
               where: s.id == ^id,
               select:
                 {fragment("?->>'adventure_id'", s.world_state),
                  fragment("?->>'game_system'", s.world_state)}
           ) do
      for_world(%{"adventure_id" => adventure_id, "game_system" => game_system})
    else
      _ -> @empty
    end
  end

  def for_session(_session_id), do: @empty
end
