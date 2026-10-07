defmodule TalesForge.Schemas.CharacterMemory do
  @moduledoc """
  Ecto schema: one character's own, personality-filtered view of an event.
  The event itself lives once in the shared `session_events` table; several
  characters can remember it differently (felt, salience, secret).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(memory promise reaction fact)

  schema "character_memories" do
    field :kind, :string
    field :text, :string
    field :felt, :string
    field :salience, :float, default: 0.5
    field :secret, :boolean, default: false
    field :tick, :integer

    belongs_to :character, TalesForge.Schemas.Character
    belongs_to :session_event, TalesForge.Schemas.SessionEvent

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "The allowed memory kinds."
  def kinds, do: @kinds

  def changeset(memory, attrs) do
    memory
    |> cast(attrs, [
      :character_id,
      :session_event_id,
      :kind,
      :text,
      :felt,
      :salience,
      :secret,
      :tick
    ])
    |> validate_required([:character_id, :kind, :text])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:salience, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> assoc_constraint(:character)
    |> check_constraint(:kind, name: :character_memories_kind_check)
  end
end
