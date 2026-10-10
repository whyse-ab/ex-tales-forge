defmodule TalesForge.Repo.Migrations.BoardPrsWaitInBuilding do
  @moduledoc """
  A PR that waits for a founder's OK keeps its card in Building (Fredrik,
  2026-10-10, 15:08). Founder check is only for the refined idea, so this
  moves every card in Founder check that has a PR back to Building, with a
  line in its history. The PR's approvals stay as they are.
  """
  use Ecto.Migration

  def up do
    execute("""
    INSERT INTO board_transitions (id, idea_id, "from", "to", actor, note, inserted_at)
    SELECT gen_random_uuid(), id, 'check', 'building', 'board',
           'Moved back to Building: a PR waits for approval in Building now (decision 2026-10-10).',
           now()
    FROM board_ideas WHERE "column" = 'check' AND pr_number IS NOT NULL
    """)

    execute("""
    UPDATE board_ideas SET "column" = 'building', updated_at = now()
    WHERE "column" = 'check' AND pr_number IS NOT NULL
    """)
  end

  def down, do: :ok
end
