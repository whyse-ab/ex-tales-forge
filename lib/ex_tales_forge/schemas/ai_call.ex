defmodule TalesForge.Schemas.AICall do
  @moduledoc """
  One LLM request: tokens, cost in micro-USD and latency, linked to a session and turn.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "ai_calls" do
    field :turn_number, :integer
    field :purpose, :string
    field :model, :string
    field :status, :string
    field :latency_ms, :integer
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :cached_tokens, :integer
    field :reasoning_tokens, :integer
    field :cost_micro_usd, :integer
    field :cost_source, :string

    belongs_to :game_session, TalesForge.Schemas.GameSession

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @fields [
    :game_session_id,
    :turn_number,
    :purpose,
    :model,
    :status,
    :latency_ms,
    :input_tokens,
    :output_tokens,
    :cached_tokens,
    :reasoning_tokens,
    :cost_micro_usd,
    :cost_source
  ]

  def changeset(ai_call, attrs) do
    ai_call
    |> cast(attrs, @fields)
    |> validate_required([:purpose, :model, :status, :latency_ms])
    |> validate_inclusion(:status, ~w(ok error capped))
    |> validate_inclusion(:cost_source, ~w(provider price_table))
    |> foreign_key_constraint(:game_session_id)
  end
end
