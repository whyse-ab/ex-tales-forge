defmodule TalesForge.Board.Link do
  @moduledoc "A link on a card (`board_links`): the PR, the playtest, the decision commit, a doc."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(pr playtest decision doc other)

  @typedoc "A link."
  @type t :: %__MODULE__{}

  schema "board_links" do
    field :kind, :string
    field :url, :string
    field :label, :string
    field :added_by, :string
    belongs_to :idea, TalesForge.Board.Idea
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "The link kinds."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "Changeset: an http(s) URL of a known kind."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:idea_id, :kind, :url, :label, :added_by])
    |> validate_required([:idea_id, :kind, :url, :added_by])
    |> validate_inclusion(:kind, @kinds)
    |> validate_format(:url, ~r{\Ahttps?://\S+\z})
    |> unique_constraint([:idea_id, :kind, :url])
  end
end
