defmodule TalesForge.Images do
  @moduledoc """
  The shared image store for idea board cards and the team chat (decision
  2026-10-10 "Screen capture in chat").

  - Founders add PNG, JPEG or WebP images up to #{div(5_000_000, 1_000_000)} MB:
    paste, drag, pick a file, or capture one still of a tab, window or screen.
    The LiveViews receive the files through LiveView uploads.
  - `store/3` reads the first bytes of the file to find the type
    (`sniff/1`). The file name extension does not decide the type.
  - Postgres keeps the bytes (`team_images.data`). Each image belongs to one
    card or one chat message, and goes when its owner goes.
  - Signed-in team members open an image at `path/1` (`/team/images/:id`).
    Bots open it at `api_url/1` (`/internal/images/:id`) with their board token.
  - `delete_for_idea/1` removes the images of a card. The board calls it when a
    card moves to Done.
  """

  import Ecto.Query

  alias TalesForge.AppRole
  alias TalesForge.Images.Image
  alias TalesForge.Repo

  @max_bytes 5_000_000
  @types ~w(image/png image/jpeg image/webp)
  @extensions ~w(.png .jpg .jpeg .webp)

  @typedoc "The owner of an image: a board card or a chat message (by id)."
  @type owner :: {:idea, Ecto.UUID.t()} | {:message, Ecto.UUID.t()}

  @doc "The largest image, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "The file extensions the upload inputs accept."
  @spec extensions() :: [String.t()]
  def extensions, do: @extensions

  @doc "The content types the store keeps."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc """
  Finds the image type from the first bytes of `data`. Returns
  `{:ok, content_type}` for PNG, JPEG and WebP, else `{:error, message}`.

      iex> TalesForge.Images.sniff(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0>>)
      {:ok, "image/png"}
      iex> TalesForge.Images.sniff(<<0xFF, 0xD8, 0xFF, 0xE0>>)
      {:ok, "image/jpeg"}
      iex> TalesForge.Images.sniff("RIFF" <> <<0, 0, 0, 0>> <> "WEBPVP8 ")
      {:ok, "image/webp"}
      iex> TalesForge.Images.sniff("GIF89a")
      {:error, "Add a PNG, JPEG or WebP image."}
  """
  @spec sniff(binary()) :: {:ok, String.t()} | {:error, String.t()}
  def sniff(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: {:ok, "image/png"}
  def sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  def sniff(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>), do: {:ok, "image/webp"}
  def sniff(_data), do: {:error, "Add a PNG, JPEG or WebP image."}

  @doc """
  Stores the image `data` for `owner`. `attrs` gives `:uploader` (a founder
  email or `bot:<name>`) and an optional `:note`. Returns `{:ok, image}`, or
  `{:error, message}` when the bytes are not PNG, JPEG or WebP, or too large.
  """
  @spec store(owner(), binary(), map()) :: {:ok, Image.t()} | {:error, String.t()}
  def store(owner, data, attrs) when is_binary(data) do
    with :ok <- check_size(data),
         {:ok, type} <- sniff(data) do
      %Image{}
      |> Image.changeset(
        attrs
        |> Map.new()
        |> Map.merge(owner_attrs(owner))
        |> Map.merge(%{content_type: type, byte_size: byte_size(data), data: data})
      )
      |> Repo.insert()
      |> case do
        {:ok, image} -> {:ok, %{image | data: nil}}
        {:error, cs} -> {:error, first_error(cs)}
      end
    end
  end

  @doc """
  Checks `data` before it goes into a transaction. Returns `:ok` or
  `{:error, message}` (the same checks as `store/3`).
  """
  @spec validate(binary()) :: :ok | {:error, String.t()}
  def validate(data) when is_binary(data) do
    with :ok <- check_size(data), {:ok, _type} <- sniff(data), do: :ok
  end

  defp check_size(data) when byte_size(data) == 0, do: {:error, "The file is empty."}

  defp check_size(data) when byte_size(data) > @max_bytes,
    do: {:error, "Add an image of #{div(@max_bytes, 1_000_000)} MB or less."}

  defp check_size(_data), do: :ok

  @doc "The changeset `attrs` that link an image to `owner`."
  @spec owner_attrs(owner()) :: map()
  def owner_attrs({:idea, id}), do: %{idea_id: id}
  def owner_attrs({:message, id}), do: %{message_id: id}

  defp first_error(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(&elem(&1, 0))
    |> Enum.flat_map(&elem(&1, 1))
    |> List.first()
  end

  @doc "The images of one card, oldest first (without the bytes)."
  @spec for_idea(Ecto.UUID.t()) :: [Image.t()]
  def for_idea(idea_id) do
    Repo.all(from i in Image, where: i.idea_id == ^idea_id, order_by: i.inserted_at)
  end

  @doc "The images of the chat messages `ids`, grouped by message id (without the bytes)."
  @spec for_messages([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => [Image.t()]}
  def for_messages([]), do: %{}

  def for_messages(ids) do
    from(i in Image, where: i.message_id in ^ids, order_by: i.inserted_at)
    |> Repo.all()
    |> Enum.group_by(& &1.message_id)
  end

  @doc "One image with its bytes, or nil for an unknown or malformed id."
  @spec get_with_data(String.t()) :: Image.t() | nil
  def get_with_data(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Repo.one(from i in Image, where: i.id == ^uuid, select_merge: %{data: i.data})

      :error ->
        nil
    end
  end

  @doc "Deletes the images of the card `idea_id`. Returns how many it deleted."
  @spec delete_for_idea(Ecto.UUID.t()) :: non_neg_integer()
  def delete_for_idea(idea_id) do
    {count, _} = Repo.delete_all(delete_query(idea_id))
    count
  end

  @doc "The query that deletes the images of the card `idea_id` (for an `Ecto.Multi`)."
  @spec delete_query(Ecto.UUID.t()) :: Ecto.Query.t()
  def delete_query(idea_id), do: from(i in Image, where: i.idea_id == ^idea_id)

  @doc "The page path of an image, for signed-in team members."
  @spec path(Image.t()) :: String.t()
  def path(%Image{id: id}), do: "/team/images/#{id}"

  @doc "The full URL of an image on production, for signed-in team members."
  @spec url(Image.t()) :: String.t()
  def url(%Image{} = image), do: base() <> path(image)

  @doc "The full URL of an image for the bots (needs a board bot token)."
  @spec api_url(Image.t()) :: String.t()
  def api_url(%Image{id: id}), do: base() <> "/internal/images/#{id}"

  defp base, do: AppRole.base_url(:production) |> String.trim_trailing("/")

  @doc "An image as JSON for the bots: links, type, size, note, uploader and time."
  @spec to_json(Image.t()) :: map()
  def to_json(%Image{} = i) do
    %{
      "id" => i.id,
      "url" => url(i),
      "api_url" => api_url(i),
      "content_type" => i.content_type,
      "byte_size" => i.byte_size,
      "note" => i.note,
      "uploader" => i.uploader,
      "at" => i.inserted_at
    }
  end
end
