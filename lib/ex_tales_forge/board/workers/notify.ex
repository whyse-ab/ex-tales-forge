defmodule TalesForge.Board.Workers.Notify do
  @moduledoc """
  Wakes a bot about a board event: a signed JSON POST to that bot's webhook
  (`BOARD_WEBHOOK_URL_<BOT>`, key `BOARD_WEBHOOK_KEY_<BOT>`; config
  `:board_bots`, `TalesForge.BoardApi.bot_config/1`).

  Request: `Content-Type: application/json`, `Authorization: Bearer <key>`,
  `X-Board-Event`, `X-Board-Delivery` (a UUID, the same on every retry, so the
  bot can drop duplicates), `X-Board-Timestamp` (Unix seconds) and
  `X-Board-Signature: sha256=<hex HMAC-SHA256 of "<timestamp>.<body>" with the
  key>`. Body: `event`, `delivery_id`, `bot`, `idea` (id, title, column, url),
  `transition` (from, to, actor) and, for a mention, `comment`.

  Any 2xx ends it. Otherwise Oban retries up to 8 times with backoff (1 min,
  2, 4 ... up to 4 h). A bot without a URL is skipped (the job is cancelled).
  Queue `:board`.
  """

  use Oban.Worker, queue: :board, max_attempts: 8

  alias TalesForge.Board
  alias TalesForge.Board.Idea
  alias TalesForge.BoardApi

  @doc "The job that wakes `bot` about `event` on `idea`."
  @spec job(BoardApi.bot(), atom(), Idea.t(), map()) :: Oban.Job.changeset()
  def job(bot, event, %Idea{} = idea, extra) do
    new(%{
      "bot" => Atom.to_string(bot),
      "event" => event_name(event),
      "delivery_id" => Ecto.UUID.generate(),
      "payload" =>
        %{
          "idea" => %{
            "id" => idea.id,
            "title" => idea.title,
            "column" => extra[:to] || idea.column,
            "url" => Board.url(idea)
          },
          "transition" => Map.take(stringify(extra), ~w(from to actor)),
          "comment" => if(extra[:body], do: %{"author" => extra[:author], "body" => extra[:body]})
        }
        |> Map.merge(pr_fields(extra))
    })
  end

  # pr.approved / pr.changes_requested: the PR, the founder and the comment.
  defp pr_fields(%{pr: pr} = extra),
    do: %{"pr" => pr, "approver" => extra[:approver], "comment" => extra[:comment]}

  defp pr_fields(%{question: q}), do: %{"question" => q}
  defp pr_fields(_extra), do: %{}

  @doc """
  The event's wire name.

      iex> TalesForge.Board.Workers.Notify.event_name(:idea_to_refining)
      "idea.to_refining"
  """
  @spec event_name(atom()) :: String.t()
  def event_name(event) do
    case Atom.to_string(event) do
      "idea_" <> rest -> "idea." <> rest
      other -> String.replace(other, "_", ".", global: false)
    end
  end

  @doc "The signature header value for `body` sent at `timestamp` with `key`."
  @spec signature(String.t(), String.t(), String.t()) :: String.t()
  def signature(key, timestamp, body),
    do:
      "sha256=" <>
        Base.encode16(:crypto.mac(:hmac, :sha256, key, timestamp <> "." <> body), case: :lower)

  @impl Oban.Worker
  @spec backoff(Oban.Job.t()) :: pos_integer()
  def backoff(%Oban.Job{attempt: attempt}), do: min(60 * Integer.pow(2, attempt - 1), 4 * 3600)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"bot" => bot} = args}) do
    config = BoardApi.bot_config(String.to_existing_atom(bot))

    case {config[:webhook_url], config[:webhook_key]} do
      {url, key} when is_binary(url) and is_binary(key) -> post(url, key, args)
      _ -> {:cancel, "no webhook URL and key for #{bot}"}
    end
  end

  defp post(url, key, args) do
    body =
      Jason.encode!(
        Map.merge(args["payload"], %{
          "event" => args["event"],
          "delivery_id" => args["delivery_id"],
          "bot" => args["bot"]
        })
      )

    ts = Integer.to_string(System.system_time(:second))

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer " <> key},
      {"x-board-event", args["event"]},
      {"x-board-delivery", args["delivery_id"]},
      {"x-board-timestamp", ts},
      {"x-board-signature", signature(key, ts, body)}
    ]

    opts = [body: body, headers: headers, retry: false, receive_timeout: 15_000]

    case Req.post(
           url,
           Keyword.merge(opts, Application.get_env(:ex_tales_forge, :board_req_options, []))
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, "webhook answered #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
end
