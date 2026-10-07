defmodule TalesForge.Schemas.Character.Ocean do
  @moduledoc "Embedded: the five OCEAN traits, 0–10 each, fixed for the session. Missing traits default to 5."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @fields ~w(openness conscientiousness extraversion agreeableness neuroticism)a

  embedded_schema do
    for f <- @fields, do: field(f, :integer, default: 5)
  end

  def changeset(ocean, attrs) do
    ocean
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> then(fn cs ->
      Enum.reduce(
        @fields,
        cs,
        &validate_number(&2, &1, greater_than_or_equal_to: 0, less_than_or_equal_to: 10)
      )
    end)
  end
end
