defmodule TalesForge.Schemas.Character.Stats do
  @moduledoc "Embedded: the six ability scores. NPCs default to 10, so one roll formula serves both."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @fields ~w(str dex con int wis cha)a

  embedded_schema do
    for f <- @fields, do: field(f, :integer, default: 10)
  end

  def changeset(stats, attrs) do
    stats
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> then(fn cs ->
      Enum.reduce(@fields, cs, &validate_number(&2, &1, greater_than_or_equal_to: 1))
    end)
  end

  @doc "Converts a sheet map (`\"STR\" => 12`, …) into changeset params (`str: 12`, …)."
  def from_sheet(sheet) when is_map(sheet) do
    Map.new(@fields, fn f ->
      key = f |> Atom.to_string() |> String.upcase()
      {f, Map.get(sheet, key, Map.get(sheet, Atom.to_string(f), 10))}
    end)
  end

  def from_sheet(_), do: from_sheet(%{})
end
