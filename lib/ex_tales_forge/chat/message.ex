defmodule TalesForge.Chat.Message do
  @moduledoc """
  One message in the team chat (`TalesForge.Chat`): the author (a founder
  email or `bot:<name>`), the text, the founder handles and bots it
  mentions (`TalesForge.Board.Mentions`), and its images
  (`TalesForge.Images`). A message with an image can have an empty text.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @max 2_000

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "team_chat_messages" do
    field :author, :string
    field :body, :string
    field :mentions, {:array, :string}, default: []
    field :bots, {:array, :string}, default: []
    has_many :images, TalesForge.Images.Image, foreign_key: :message_id
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The longest message, in characters."
  @spec max_length() :: pos_integer()
  def max_length, do: @max

  @doc """
  A changeset for a new message. The text is required, except when
  `opts[:images?]` is true (the message has an image).
  """
  @spec changeset(t(), map(), keyword()) :: Ecto.Changeset.t()
  def changeset(message, attrs, opts \\ []) do
    required = if opts[:images?], do: [:author], else: [:author, :body]

    message
    |> cast(attrs, [:author, :body, :mentions, :bots])
    |> update_change(:body, &String.trim/1)
    |> validate_required(required, message: "Write a message first.")
    |> then(&if(get_field(&1, :body), do: &1, else: put_change(&1, :body, "")))
    |> validate_length(:body, max: @max, message: "Write #{@max} characters or fewer.")
  end
end
