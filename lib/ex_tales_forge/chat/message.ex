defmodule TalesForge.Chat.Message do
  @moduledoc """
  One message in the team chat (`TalesForge.Chat`): the author (a founder
  email or `bot:<name>`), the text, and the founder handles and bots it
  mentions (`TalesForge.Board.Mentions`).
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
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc "The longest message, in characters."
  @spec max_length() :: pos_integer()
  def max_length, do: @max

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    message
    |> cast(attrs, [:author, :body, :mentions, :bots])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:author, :body], message: "Write a message first.")
    |> validate_length(:body, max: @max, message: "Write #{@max} characters or fewer.")
  end
end
