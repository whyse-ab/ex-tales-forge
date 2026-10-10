defmodule TalesForge.ChatTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.Chat

  doctest TalesForge.Chat

  @fredrik "fredrik@whyse.se"
  @max "max@example.com"

  defp wakes do
    Oban.Job |> Repo.all() |> Enum.filter(&(&1.args["event"] == "chat.mention"))
  end

  test "a message is kept, broadcast and shows in recent/0" do
    Chat.subscribe()
    {:ok, m} = Chat.post(@fredrik, "  Hello team  ")
    assert m.body == "Hello team"
    assert_receive {:team_chat, %{id: id}} when id == m.id
    assert [%{body: "Hello team"}] = Chat.recent()
  end

  test "an empty or too long message is refused with a clear reason" do
    assert {:error, cs} = Chat.post(@fredrik, "   ")
    assert "Write a message first." in errors_on(cs).body

    assert {:error, cs} = Chat.post(@fredrik, String.duplicate("a", 2_001))
    assert "Write 2000 characters or fewer." in errors_on(cs).body
  end

  test "founder mentions give an unread badge until the founder opens the chat" do
    {:ok, _} = Chat.post(@fredrik, "@max can you look? cc @fredrik")
    {:ok, _} = Chat.post(@fredrik, "@founders standup at 16")

    assert Chat.unread(@max) == 2
    # The author is never pinged by their own message.
    assert Chat.unread(@fredrik) == 0

    :ok = Chat.mark_read(@max)
    assert Chat.unread(@max) == 0
  end

  test "a founder's bot mention wakes the bot through the webhook outbox" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, _} = Chat.post(@fredrik, "first")
      {:ok, m} = Chat.post(@fredrik, "@Case please look at the board")

      assert [job] = wakes()
      assert job.worker == "TalesForge.Board.Workers.Notify"
      assert job.args["bot"] == "case"
      assert job.args["payload"]["chat"]["message"]["id"] == m.id
      assert [%{"body" => "first"}] = job.args["payload"]["chat"]["recent"]
      assert job.args["payload"]["chat"]["reply_url"] =~ "/internal/chat"
    end)
  end

  test "a bot's mention of a bot wakes nobody (bot costs)" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      {:ok, m} = Chat.post("bot:case", "@bobby this one is yours")
      assert m.bots == ["bobby"]
      assert wakes() == []
    end)
  end

  test "the bots' API reads and posts as the bot" do
    {201, %{"author" => "bot:gentry", "body" => "Checked."}} =
      Chat.api(:create, :gentry, %{"body" => "Checked."})

    {200, %{"messages" => [%{"author" => "bot:gentry"}]}} = Chat.api(:index, :gentry, %{})
    {422, %{"errors" => %{body: _}}} = Chat.api(:create, :gentry, %{"body" => ""})
  end
end
