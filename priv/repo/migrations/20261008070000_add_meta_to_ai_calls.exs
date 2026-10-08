defmodule TalesForge.Repo.Migrations.AddMetaToAiCalls do
  use Ecto.Migration

  # Call details that are not tokens or cost, e.g. the input safety read's
  # label, confidence and whether the GM got the player's quote
  # (TalesForge.Game.PlayerQuote). Nullable; existing rows keep NULL.
  def change do
    alter table(:ai_calls) do
      add :meta, :map
    end
  end
end
