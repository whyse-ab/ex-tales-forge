defmodule TalesForge.Collab.Schemas.Decision do
  @moduledoc """
  A ranked founder decision, indexed from the tales-forge-docs repo.
  Git remains the source of truth for content; DB holds live UI state
  (rank changes, comments, interested, recorded outcomes) for now.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(open discussing decided superseded)

  schema "collab_decisions" do
    field :slug, :string
    field :title, :string
    field :rank, :integer, default: 999
    field :status, :string, default: "open"
    field :options, {:array, :string}, default: []
    field :decision, :string
    field :rationale, :string
    field :decided_at, :utc_datetime
    field :links, {:array, :string}, default: []
    field :body, :string, default: ""
    field :source_path, :string

    has_many :comments, TalesForge.Collab.Schemas.Comment
    has_many :interests, TalesForge.Collab.Schemas.Interest

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [
      :slug,
      :title,
      :rank,
      :status,
      :options,
      :decision,
      :rationale,
      :decided_at,
      :links,
      :body,
      :source_path
    ])
    |> validate_required([:slug, :title, :rank, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:slug)
  end

  def record_outcome_changeset(decision, attrs) do
    decision
    |> cast(attrs, [:decision, :rationale, :status, :decided_at])
    |> validate_required([:decision, :rationale, :status, :decided_at])
    |> validate_inclusion(:status, ["decided"])
  end
end
