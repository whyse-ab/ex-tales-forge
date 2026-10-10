defmodule TalesForge.Repo.Migrations.BoardUsecTimestamps do
  @moduledoc """
  Microsecond timestamps on the idea board's history and comments, so moves and
  comments made within the same second keep their order.
  """
  use Ecto.Migration

  def change do
    for table <- [:board_transitions, :board_comments] do
      alter table(table) do
        modify :inserted_at, :utc_datetime_usec, from: :utc_datetime
      end
    end
  end
end
