defmodule TalesForge.Repo.Migrations.DropAuthoringTables do
  @moduledoc """
  Drops the tables of the removed Ash authoring layer (adventures, locations,
  npc_definitions). Nothing reads them any more: worlds and NPCs come from the
  pack files under priv/.

  Safety check: `up` refuses to run while any of the three tables still holds
  a row, so authored data can't be dropped by accident. Export or delete the
  rows first. `down` recreates the empty tables and indexes exactly as the
  original migrations (20260709120000, 121000, 122000) made them.
  """

  use Ecto.Migration

  @tables ~w(adventures locations npc_definitions)

  def up do
    assert_tables_empty!(repo())

    drop table(:locations)
    drop table(:adventures)
    drop table(:npc_definitions)
  end

  def down do
    create table(:npc_definitions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :npc_id, :string, null: false
      add :name, :string, null: false
      add :race, :string
      add :role, :string
      add :default_location_id, :string

      add :appearance, :text
      add :personality, :text
      add :backstory, :text

      add :motivations, :map, default: %{}
      add :stock, {:array, :map}, default: []

      add :portrait_url, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:npc_definitions, [:npc_id])

    create table(:adventures, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :adventure_id, :string, null: false
      add :name, :string, null: false
      add :synopsis, :text
      add :starting_location_id, :string
      add :initial_present_npc_ids, {:array, :string}, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:adventures, [:adventure_id])

    create table(:locations, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :location_id, :string, null: false
      add :adventure_id, :string, null: false
      add :name, :string, null: false
      add :exits, {:array, :string}, default: []
      add :blurb, :text
      add :fixtures, {:array, :string}, default: []
      add :ground_items, {:array, :map}, default: []
      add :scene_image_url, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:locations, [:adventure_id, :location_id])
    create index(:locations, [:adventure_id])
  end

  @doc "Raises unless adventures, locations and npc_definitions are all empty."
  def assert_tables_empty!(repo) do
    counts =
      Enum.map(@tables, fn table ->
        %{rows: [[count]]} = repo.query!("SELECT count(*) FROM #{table}")
        {table, count}
      end)

    case Enum.filter(counts, fn {_table, count} -> count > 0 end) do
      [] ->
        :ok

      non_empty ->
        details = Enum.map_join(non_empty, ", ", fn {table, count} -> "#{table}: #{count}" end)

        raise "Refusing to drop the authoring tables: they still hold rows (#{details}). " <>
                "Export or delete them first, then rerun the migration."
    end
  end
end
