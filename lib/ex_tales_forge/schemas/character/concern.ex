defmodule TalesForge.Schemas.Character.Concern do
  @moduledoc "Embedded: one thing a character is worried about or working towards (at most three per character)."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @statuses ~w(open resolved dropped)

  embedded_schema do
    field :text, :string
    field :focus, :string
    field :priority, :integer, default: 5
    field :since_tick, :integer
    field :status, :string, default: "open"
    field :blocked_by, :string
  end

  def changeset(concern, attrs) do
    concern
    |> cast(attrs, [:text, :focus, :priority, :since_tick, :status, :blocked_by])
    |> validate_required([:text, :priority, :status])
    |> validate_number(:priority, greater_than_or_equal_to: 1, less_than_or_equal_to: 10)
    |> validate_inclusion(:status, @statuses)
  end
end
