defmodule TalesForge.Repo.Migrations.BoardIdeaTags do
  use Ecto.Migration

  # Free-text tags that founders put on an idea board card (add only).
  def change do
    alter table(:board_ideas) do
      add :tags, {:array, :string}, null: false, default: []
    end
  end
end
