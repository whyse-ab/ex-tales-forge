defmodule TalesForge.Repo.Migrations.BoardVoteReason do
  @moduledoc "A downvote has a reason (Fredrik, 2026-10-10); it goes with the vote."
  use Ecto.Migration

  def change do
    alter table(:board_votes) do
      add :reason, :text
    end
  end
end
