defmodule TalesForge.Repo.Migrations.AddCallTypeAndTagsToAiCalls do
  @moduledoc """
  ai_calls gets the call type from docs/call-types.md (function | jev | llm),
  world/module and game-system tags, the x-grok-conv-id the call was sent with
  and a microsecond start time (for the idle gap before a GM call).

  Backfill, only where it is cheap and unambiguous:

  - call_type: every existing row is an LLM call except Jev scorer rows, which
    are the only rows with a `jev-*` model. The column default ('llm') covers
    the rest, and any row written by an older release during a deploy.
  - adventure_id: from the session's world_state.
  - game_system: 'skill_d20' (the 1d20 roll-under skill system in priv/rules,
    which every adventure pack uses today) where the adventure is known.

  conv_id and started_at stay NULL on old rows: conv ids changed twice on
  2026-10-07 (#34, #37), so the id an old row was sent with can't be told from
  its purpose. Metrics fall back to inserted_at - latency_ms for old rows.
  """
  use Ecto.Migration

  @backfill [
    "UPDATE ai_calls SET call_type = 'jev' WHERE model LIKE 'jev-%'",
    """
    UPDATE ai_calls AS c SET adventure_id = s.world_state->>'adventure_id'
    FROM game_sessions AS s
    WHERE c.game_session_id = s.id AND c.adventure_id IS NULL
    """,
    "UPDATE ai_calls SET game_system = 'skill_d20' WHERE adventure_id IS NOT NULL AND game_system IS NULL"
  ]

  @doc false
  def backfill_sql, do: @backfill

  def up do
    alter table(:ai_calls) do
      add :call_type, :string, null: false, default: "llm"
      add :adventure_id, :string
      add :game_system, :string
      add :conv_id, :string
      add :started_at, :utc_datetime_usec
    end

    create index(:ai_calls, [:call_type, :inserted_at])

    flush()

    Enum.each(@backfill, &execute/1)
  end

  def down do
    drop index(:ai_calls, [:call_type, :inserted_at])

    alter table(:ai_calls) do
      remove :call_type
      remove :adventure_id
      remove :game_system
      remove :conv_id
      remove :started_at
    end
  end
end
