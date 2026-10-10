defmodule TalesForge.Board.Typing do
  @moduledoc """
  "Fredrik is typing…" on the idea board (card "Writing in the comment field
  in cards", 2026-10-10). A founder who writes in a card's comment box is
  tracked with Phoenix Presence on the "board:typing" topic, under their LiveView process.
  This is a hint, not a lock: everyone can still write, and comments save one
  by one. The hint goes when the founder posts, closes the card, stops for a
  few seconds (`TalesForgeWeb.TeamIdeaBoard` untracks them), or leaves the page
  (Presence removes a process that stops).

  A start or a stop sends `{:board, :changed}` on the board topic, so every
  open board shows the change. Each keystroke after the start sends nothing.
  """

  alias TalesForgeWeb.Presence

  @topic "board:typing"

  @doc "The Presence topic."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "The founder (email) writes a comment on the card. Returns true when this is a new start."
  @spec start(String.t(), String.t()) :: boolean()
  def start(idea_id, email) do
    case Presence.track(self(), @topic, key(idea_id, email), %{idea_id: idea_id, email: email}) do
      {:ok, _} -> changed(true)
      _ -> false
    end
  end

  @doc "The founder stopped writing on the card (posted, closed it, or paused)."
  @spec stop(String.t(), String.t()) :: :ok
  def stop(idea_id, email) do
    if Map.has_key?(Presence.list(@topic), key(idea_id, email)) do
      Presence.untrack(self(), @topic, key(idea_id, email))
      changed(true)
    end

    :ok
  end

  @doc "Who writes on which card now: card id to emails (sorted)."
  @spec who() :: %{String.t() => [String.t()]}
  def who do
    @topic
    |> Presence.list()
    |> Enum.flat_map(fn {_key, %{metas: metas}} -> metas end)
    |> Enum.group_by(& &1.idea_id, & &1.email)
    |> Map.new(fn {id, emails} -> {id, emails |> Enum.uniq() |> Enum.sort()} end)
  end

  @doc """
  The hint text for the names, without the reader's own name.

      iex> TalesForge.Board.Typing.hint(["fredrik@whyse.se"], "max@example.com")
      "Fredrik is typing…"
      iex> TalesForge.Board.Typing.hint(["fredrik@whyse.se", "max@example.com"], "jo@example.com")
      "Fredrik and Max are typing…"
      iex> TalesForge.Board.Typing.hint(["max@example.com"], "max@example.com")
      nil
  """
  @spec hint([String.t()], String.t() | nil) :: String.t() | nil
  def hint(emails, me) do
    case emails |> List.delete(me) |> Enum.map(&TalesForge.TeamOnline.name/1) do
      [] -> nil
      [one] -> "#{one} is typing…"
      names -> "#{names |> Enum.drop(-1) |> Enum.join(", ")} and #{List.last(names)} are typing…"
    end
  end

  defp key(idea_id, email), do: "#{idea_id}|#{email}"

  defp changed(result) do
    Phoenix.PubSub.broadcast(TalesForge.PubSub, TalesForge.Board.topic(), {:board, :changed})
    result
  end
end
