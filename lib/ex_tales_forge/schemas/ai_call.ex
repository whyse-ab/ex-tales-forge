defmodule TalesForge.Schemas.AICall do
  @moduledoc """
  One unit of recorded work: tokens, cost in micro-USD and latency, linked to a session and turn.

  `call_type` follows docs/call-types.md in tales-forge-docs:

  - `"llm"`: an xAI (or other provider) chat completion. `conv_id` is the
    `x-grok-conv-id` it was sent with.
  - `"jev"`: a TypeSafe Jev call (typed answer from free text).
  - `"function"`: a timed Elixir step of a turn (`purpose` `turn.*`), cost 0.

  `adventure_id` (world/module) and `game_system` tag every row so costs can be
  split per adventure and rules system. `started_at` (microseconds) is when the
  request or step began; `inserted_at` is when it was recorded. `meta` holds
  call details that are not tokens or cost, e.g. the Jev intent read, its band,
  safety label and quote decision, or the shadow diff (`TalesForge.IntentJev`).
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
    field :call_type, :string, default: "llm"
    field :adventure_id, :string
    field :game_system, :string
    field :conv_id, :string
    field :started_at, :utc_datetime_usec
    field :meta, :map

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
    :cost_source,
    :call_type,
    :adventure_id,
    :game_system,
    :conv_id,
    :started_at,
    :meta
  ]

  @call_types ~w(function jev llm)

  def call_types, do: @call_types

  def changeset(ai_call, attrs) do
    ai_call
    |> cast(attrs, @fields)
    |> validate_required([:purpose, :model, :status, :latency_ms, :call_type])
    |> validate_inclusion(:status, ~w(ok error capped))
    |> validate_inclusion(:call_type, @call_types)
    |> validate_inclusion(:cost_source, ~w(provider price_table free))
    |> foreign_key_constraint(:game_session_id)
  end
end
