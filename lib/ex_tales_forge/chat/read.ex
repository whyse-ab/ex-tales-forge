defmodule TalesForge.Chat.Read do
  @moduledoc "When a founder (by handle) last opened the team chat."

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key {:handle, :string, autogenerate: false}
  schema "team_chat_reads" do
    field :read_at, :utc_datetime_usec
  end
end
