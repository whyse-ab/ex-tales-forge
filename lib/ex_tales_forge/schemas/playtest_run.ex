defmodule TalesForge.Schemas.PlaytestRun do
  @moduledoc """
  One persona bot run (`TalesForge.Playtest.Runner`). Its session is a bot session.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(running finished stopped failed)
  @stop_reasons ~w(ended turn_limit spend_cap dead error timeout)

  schema "playtest_runs" do
    field :persona, :string
    field :module, :string
    field :build, :string
    field :turn_limit, :integer
    field :turns_played, :integer, default: 0
    field :status, :string
    field :stop_reason, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :notes, :string

    belongs_to :game_session, TalesForge.Schemas.GameSession

    timestamps(type: :utc_datetime)
  end

  @fields [
    :game_session_id,
    :persona,
    :module,
    :build,
    :turn_limit,
    :turns_played,
    :status,
    :stop_reason,
    :started_at,
    :finished_at,
    :notes
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
