defmodule TalesForge.Images.Image do
  @moduledoc """
  One image in the shared image store (`TalesForge.Images`). The image
  belongs to one idea board card (`idea_id`) or to one team chat message
  (`message_id`). The bytes are in `data`. A normal query does not load
  `data`, so lists of images stay small; `TalesForge.Images.data/1` reads it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          idea_id: Ecto.UUID.t() | nil,
          message_id: Ecto.UUID.t() | nil,
          uploader: String.t() | nil,
          content_type: String.t() | nil,
          byte_size: non_neg_integer() | nil,
          note: String.t() | nil,
          data: binary() | nil,
          inserted_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "team_images" do
    field :idea_id, :binary_id
    field :message_id, :binary_id
    field :uploader, :string
    field :content_type, :string
    field :byte_size, :integer
    field :note, :string
    field :data, :binary, load_in_query: false
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "A changeset for a new image. The note is trimmed; an empty note becomes nil."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(image, attrs) do
    image
    |> cast(attrs, [:idea_id, :message_id, :uploader, :content_type, :byte_size, :note, :data])
    |> update_change(:note, &blank_to_nil/1)
    |> validate_required([:uploader, :content_type, :byte_size, :data])
    |> validate_length(:note, max: 2_000)
    |> check_constraint(:idea_id, name: :one_owner, message: "An image needs one owner.")
  end

  defp blank_to_nil(note) do
    case String.trim(note) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
