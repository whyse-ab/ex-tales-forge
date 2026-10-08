defmodule TalesForge.Survey.Snapshot do
  @moduledoc """
  A survey file exactly as it was when answers were saved under it
  (`survey_definitions`), one row per distinct SHA-256. Written on save by
  `TalesForge.Surveys`, so later wording edits in tales-forge-docs never
  change what an old answer was an answer to.
  """

  use Ecto.Schema

  @typedoc "A stored survey file."
  @type t :: %__MODULE__{
          id: integer() | nil,
          survey_id: String.t() | nil,
          version: integer() | nil,
          sha256: String.t() | nil,
          source: String.t() | nil,
          body: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  schema "survey_definitions" do
    field :survey_id, :string
    field :version, :integer
    field :sha256, :string
    field :source, :string
    field :body, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
