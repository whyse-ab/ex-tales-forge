defmodule TalesForge.Repo.Migrations.AddMetaToAiCalls do
  use Ecto.Migration

  # Call details that are not tokens or cost: the Jev intent read, its band and
  # safety label, the quote decision and, in shadow mode, the diff against the
  # current intent path (TalesForge.IntentJev). Nullable; existing rows keep NULL.
  #
  # Same version as the closed #76 branch, which playtest already ran, so
  # playtest skips it; IF NOT EXISTS keeps it safe either way.
  def change do
    alter table(:ai_calls) do
      add_if_not_exists :meta, :map
    end
  end
end
