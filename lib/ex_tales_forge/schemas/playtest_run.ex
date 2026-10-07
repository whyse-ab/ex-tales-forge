defmodule TalesForge.Schemas.PlaytestRun do
  @moduledoc """
  One persona bot run (`TalesForge.Playtest.Runner`). Its session is a bot session.

  `build` is the app version and Fly image id; `git_sha` is the release's git
  commit and `flags` the switches, variant and models in force when the run
  started (`TalesForge.Playtest.RunMeta`).

  `game_ms` is the game's time (action submitted to turn done, plus scene waits);
  the persona_* totals are the bot's own calls, kept apart from the game's cost.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(running finished stopped failed)
  @stop_reasons ~w(ended turn_limit spend_cap persona_cap dead error timeout)

  schema "playtest_runs" do
    field :persona, :string
    field :module, :string
    field :build, :string
    field :git_sha, :string
    field :flags, :map, default: %{}
    field :turn_limit, :integer
    field :turns_played, :integer, default: 0
    field :status, :string
    field :stop_reason, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :notes, :string
    field :game_ms, :integer, default: 0
    field :persona_calls, :integer, default: 0
    field :persona_ms, :integer, default: 0
    field :persona_input_tokens, :integer, default: 0
    field :persona_output_tokens, :integer, default: 0
    field :persona_cost_micro_usd, :integer, default: 0

    belongs_to :game_session, TalesForge.Schemas.GameSession

    timestamps(type: :utc_datetime)
  end

  @fields [
    :game_session_id,
    :persona,
    :module,
    :build,
    :git_sha,
    :flags,
    :turn_limit,
    :turns_played,
    :status,
    :stop_reason,
    :started_at,
    :finished_at,
    :notes,
    :persona_calls,
    :persona_ms,
    :persona_input_tokens,
    :persona_output_tokens,
    :persona_cost_micro_usd
  ]

  def changeset(run, attrs) do
    run
    |> cast(attrs, @fields)
    |> validate_required([:game_session_id, :persona, :module, :turn_limit, :status, :started_at])
    |> validate_number(:turn_limit, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:stop_reason, @stop_reasons)
    |> foreign_key_constraint(:game_session_id)
  end
end
