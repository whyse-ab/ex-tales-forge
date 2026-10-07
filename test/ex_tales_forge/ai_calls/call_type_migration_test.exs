defmodule TalesForge.AICalls.CallTypeMigrationTest do
  use TalesForge.DataCase, async: true

  alias TalesForge.GameSessions
  alias TalesForge.Schemas.AICall

  @migration "priv/repo/migrations/20261007100000_add_call_type_and_tags_to_ai_calls.exs"
  @module TalesForge.Repo.Migrations.AddCallTypeAndTagsToAiCalls

  setup_all do
    unless Code.ensure_loaded?(@module), do: Code.require_file(@migration)
    :ok
  end

  test "adds call_type (NOT NULL, default llm), tags, conv_id and a microsecond started_at" do
    %{rows: rows} =
      Repo.query!("""
      SELECT column_name, data_type, is_nullable, column_default, datetime_precision
      FROM information_schema.columns
      WHERE table_name = 'ai_calls'
        AND column_name IN ('call_type', 'adventure_id', 'game_system', 'conv_id', 'started_at')
      ORDER BY column_name
      """)

    assert [
             ["adventure_id", "character varying", "YES", nil, nil],
             ["call_type", "character varying", "NO", "'llm'::character varying", nil],
             ["conv_id", "character varying", "YES", nil, nil],
             ["game_system", "character varying", "YES", nil, nil],
             ["started_at", "timestamp without time zone", "YES", nil, 6]
           ] = rows

    assert :purpose in AICall.__schema__(:fields)
  end

  test "backfill: Jev rows become jev, the rest stay llm, tags come from the session" do
    {:ok, tin} = GameSessions.create_session(%{name: "Tin", adventure_id: "tin_valley"})

    # Rows as an older release wrote them: no call_type (column default), no tags.
    insert_old = fn session_id, purpose, model ->
      Repo.query!(
        """
        INSERT INTO ai_calls (id, game_session_id, purpose, model, status, latency_ms, inserted_at)
        VALUES (gen_random_uuid(), $1, $2, $3, 'ok', 1, now()) RETURNING id
        """,
        [session_id && Ecto.UUID.dump!(session_id), purpose, model]
      ).rows
      |> then(fn [[id]] -> Ecto.UUID.load!(id) end)
    end

    gm = insert_old.(tin.id, "gm", "xai/grok-4.20-0309-non-reasoning")
    jev = insert_old.(tin.id, "scorer", "jev-1.13.0")
    llm_scorer = insert_old.(tin.id, "scorer", "xai/grok-4.20-0309-non-reasoning")
    orphan = insert_old.(nil, "intent", "xai/grok-4.20-0309-non-reasoning")

    Enum.each(@module.backfill_sql(), &Repo.query!/1)

    row = fn id -> Repo.get!(AICall, id) end

    assert %{call_type: "llm", adventure_id: "tin_valley", game_system: "skill_d20"} = row.(gm)
    assert %{call_type: "jev", adventure_id: "tin_valley", game_system: "skill_d20"} = row.(jev)
    assert %{call_type: "llm"} = row.(llm_scorer)
    assert %{call_type: "llm", adventure_id: nil, game_system: nil} = row.(orphan)

    # conv_id / started_at are not guessed for old rows.
    assert %{conv_id: nil, started_at: nil} = row.(gm)

    # Idempotent: running it again changes nothing.
    Enum.each(@module.backfill_sql(), &Repo.query!/1)
    assert %{call_type: "jev", adventure_id: "tin_valley"} = row.(jev)
  end
end
