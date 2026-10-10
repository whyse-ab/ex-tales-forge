defmodule TalesForge.Schemas.CodeHeatSnapshot do
  @moduledoc """
  One sample of the code heat map (`TalesForge.CodeHeat`): the call counts
  and the call time of the app's functions from `started_at` to `ended_at`.

  Each item in `rows` is one function: `"app"`, `"module"`, `"function"`
  (name/arity), `"calls"` and `"time_us"` (time in the function, in
  microseconds). `modules` is the number of traced modules.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @typedoc "A stored sample."
  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "code_heat_snapshots" do
    field :app_name, :string
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :modules, :integer, default: 0
    field :rows, {:array, :map}, default: []

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "Returns a changeset for a new sample."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:app_name, :started_at, :ended_at, :modules, :rows])
    |> validate_required([:app_name, :started_at, :ended_at])
  end
end
