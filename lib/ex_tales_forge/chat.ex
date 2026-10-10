defmodule TalesForge.Chat do
  @moduledoc """
  The team chat (board card "Team chat with mentions", decision 2026-10-10):
  one shared room for the founders and the bots. It lives on production only,
  like the board (`TalesForge.AppRole` area `:board`).

  - Messages are in `team_chat_messages` and arrive live over PubSub
    (`subscribe/0`). History stays (how long we keep it is a deferred
    question on the card).
  - Mentions use the board's one parser, `TalesForge.Board.Mentions`:
    `@fredrik`, `@founders` and `@case`, `@bobby`, `@gentry`.
  - A founder mention gives that founder an unread badge on the chat button
    (`unread/1`, by GitHub login) until they open the chat (`mark_read/1`). No email or push
    (Fredrik's answer on the card).
  - A bot mention **by a founder** wakes the bot through the board's webhook
    outbox (`TalesForge.Board.Workers.Notify`, event `chat.mention`), in the
    same transaction as the message. A bot that mentions a bot wakes nobody,
    to keep bot costs under control (Fredrik's answer on the card).
  - Bots read and write through `GET`/`POST /internal/chat` with their board
    tokens (`TalesForgeWeb.ChatApiController`, `api/3`).
  """

  import Ecto.Query

  alias Ecto.Multi
  alias TalesForge.AppRole
  alias TalesForge.Board.Mentions
  alias TalesForge.Board.Workers.Notify
  alias TalesForge.Chat.{Message, Read}
  alias TalesForge.Repo

  @topic "team_chat"
  @shown 100
  @context 10

  @doc "True where the chat lives (production and local)."
  @spec here?() :: boolean()
  def here?, do: AppRole.here?(:board)

  @doc "Subscribes the caller to `{:team_chat, message}`."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(TalesForge.PubSub, @topic)

  @doc "The latest messages, oldest first (at most #{@shown})."
  @spec recent(pos_integer()) :: [Message.t()]
  def recent(limit \\ @shown) do
    from(m in Message, order_by: [desc: m.inserted_at], limit: ^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc """
  Posts `body` as `author` (a founder email or `bot:<name>`). `opts[:login]`
  is a founder author's GitHub login, so the author gets no badge for their
  own handle (handles come from GitHub logins, `TalesForge.Board.Mentions`).
  Returns `{:ok, message}` or `{:error, changeset}`.
  """
  @spec post(String.t(), String.t(), keyword()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def post(author, body, opts \\ []) when is_binary(author) do
    body = body || ""
    %{bots: bots, founders: founders} = Mentions.parse(body)
    founders = founders -- [Mentions.handle_for(opts[:login])]
    wakes = if founder?(author), do: bots, else: []

    changeset =
      Message.changeset(%Message{}, %{
        author: author,
        body: body,
        mentions: founders,
        bots: Enum.map(bots, &Atom.to_string/1)
      })

    Multi.new()
    |> Multi.insert(:message, changeset)
    |> then(fn multi ->
      Enum.reduce(wakes, multi, fn bot, acc ->
        Oban.insert(acc, {:wake, bot}, fn %{message: m} -> wake_job(bot, m) end)
      end)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{message: message}} ->
        Phoenix.PubSub.broadcast(TalesForge.PubSub, @topic, {:team_chat, message})
        {:ok, message}

      {:error, :message, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  True for a founder author (an email), false for a bot.

      iex> TalesForge.Chat.founder?("fredrik@whyse.se")
      true
      iex> TalesForge.Chat.founder?("bot:case")
      false
  """
  @spec founder?(String.t()) :: boolean()
  def founder?("bot:" <> _), do: false
  def founder?(author), do: is_binary(author) and String.contains?(author, "@")

  @doc "The webhook job that wakes `bot` for `message` (with the last messages as context)."
  @spec wake_job(atom(), Message.t()) :: Oban.Job.changeset()
  def wake_job(bot, %Message{} = message) do
    context =
      from(m in Message,
        where: m.inserted_at < ^message.inserted_at,
        order_by: [desc: m.inserted_at],
        limit: @context
      )
      |> Repo.all()
      |> Enum.reverse()

    Notify.new(%{
      "bot" => Atom.to_string(bot),
      "event" => "chat.mention",
      "delivery_id" => Ecto.UUID.generate(),
      "payload" => %{
        "chat" => %{
          "message" => to_json(message),
          "recent" => Enum.map(context, &to_json/1),
          "reply_url" => AppRole.base_url(:production) <> "/internal/chat"
        }
      }
    })
  end

  @doc "A message as JSON for the bots."
  @spec to_json(Message.t()) :: map()
  def to_json(%Message{} = m),
    do: %{
      "id" => m.id,
      "author" => m.author,
      "body" => m.body,
      "mentions" => m.mentions,
      "bots" => m.bots,
      "at" => m.inserted_at
    }

  @doc "How many messages mention the founder with this GitHub `login` since they last opened the chat."
  @spec unread(String.t() | nil) :: non_neg_integer()
  def unread(login) do
    case Mentions.handle_for(login) do
      nil ->
        0

      handle ->
        read_at = Repo.one(from r in Read, where: r.handle == ^handle, select: r.read_at)

        from(m in Message, where: ^handle in m.mentions)
        |> then(&if(read_at, do: where(&1, [m], m.inserted_at > ^read_at), else: &1))
        |> Repo.aggregate(:count)
    end
  end

  @doc "Marks the chat as read for the founder with this GitHub `login` (they opened it)."
  @spec mark_read(String.t() | nil) :: :ok
  def mark_read(login) do
    case Mentions.handle_for(login) do
      nil ->
        :ok

      handle ->
        Repo.insert!(%Read{handle: handle, read_at: DateTime.utc_now()},
          on_conflict: {:replace, [:read_at]},
          conflict_target: :handle
        )

        :ok
    end
  end

  @doc "The handle of a founder's GitHub login, or nil (`TalesForge.Board.Mentions`)."
  @spec handle_for(String.t() | nil) :: String.t() | nil
  def handle_for(login), do: Mentions.handle_for(login)

  @doc """
  The handle to start a message to a founder with, from their email (the
  who-is-online list knows emails, not logins): the first part of the email
  when it is a founder handle, else nil.

      iex> TalesForge.Chat.handle_for_email("max@example.com", ~w(fredrik max))
      "max"
      iex> TalesForge.Chat.handle_for_email("hawkan.f@gmail.com", ~w(fredrik hakan))
      nil
  """
  @spec handle_for_email(String.t() | nil, [String.t()]) :: String.t() | nil
  def handle_for_email(email, handles \\ Mentions.handles())

  def handle_for_email(email, handles) when is_binary(email) do
    first = email |> String.downcase() |> String.split(["@", ".", "+"]) |> hd()
    if first in handles, do: first
  end

  def handle_for_email(_email, _handles), do: nil

  @doc "Text and mentions of a message body, to highlight the mentions."
  @spec segments(String.t()) :: [{:text | :mention, String.t()}]
  def segments(body), do: Mentions.segments(body)

  @doc "The handles the message box suggests."
  @spec suggestions() :: [String.t()]
  def suggestions, do: Mentions.suggestions()

  @doc """
  The bots' API (`TalesForgeWeb.ChatApiController`): `:index` gives the
  latest messages, `:create` posts `params["body"]` as the bot. A bot never
  wakes another bot.
  """
  @spec api(:index | :create, atom(), map()) :: {pos_integer(), map()}
  def api(:index, _bot, _params), do: {200, %{"messages" => Enum.map(recent(50), &to_json/1)}}

  def api(:create, bot, params) do
    case post("bot:#{bot}", to_string(params["body"] || "")) do
      {:ok, m} -> {201, to_json(m)}
      {:error, cs} -> {422, %{"errors" => Ecto.Changeset.traverse_errors(cs, &elem(&1, 0))}}
    end
  end
end
