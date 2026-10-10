defmodule TalesForge.Board.PingsTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.Board

  doctest TalesForge.Board.Mentions

  @fredrik "fredrik@whyse.se"
  @hakan "hawkan.fredriksson@gmail.com"

  test "a comment pings the founders it names, never the author; opening the card reads them" do
    {:ok, idea} = Board.create_idea(@fredrik, %{"title" => "Fishing"})
    {:ok, idea} = Board.add_comment(idea, @fredrik, "@hakan and @fredrik, what do you think?")

    assert [%{idea_id: id, title: "Fishing", count: 1, from: @fredrik}] =
             Board.unread_pings(@hakan)

    assert id == idea.id
    assert Board.unread_pings(@fredrik) == []

    {:ok, _} = Board.add_comment(idea, "bot:case", "@Håkan one more question.")
    assert [%{count: 2, from: "bot:case"}] = Board.unread_pings(@hakan)

    assert Board.read_pings(idea.id, @hakan) == 2
    assert Board.unread_pings(@hakan) == []
    assert Board.read_pings(idea.id, @hakan) == 0
  end

  test "@founders pings every founder except the author; bot mentions add no pings" do
    {:ok, idea} = Board.create_idea(@fredrik, %{"title" => "Inn"})
    {:ok, _} = Board.add_comment(idea, @hakan, "@founders vote please. @case too")

    assert [%{count: 1}] = Board.unread_pings(@fredrik)
    assert [%{count: 1}] = Board.unread_pings("max@example.com")
    assert Board.unread_pings(@hakan) == []
    assert Board.unread_pings("stranger@example.com") == []
  end

  test "saving the same answer twice writes one history line" do
    {:ok, idea} = Board.create_idea(@fredrik, %{"title" => "Questions"})
    {:ok, idea} = Board.vote(idea, @fredrik, 1)
    {:ok, idea} = Board.move(idea, {:founder, @fredrik}, "refining")

    {:ok, idea} =
      Board.refine(idea, %{
        "details" => "d",
        "open_questions" => ["Why?"],
        "rough_cost" => "S",
        "verdict" => "feasible"
      })

    {:ok, _} = Board.answer_question(idea, @fredrik, "Why?", %{"answer" => "Fun."})
    {:ok, idea} = Board.answer_question(idea, @fredrik, "Why?", %{"answer" => "Fun."})
    {:ok, idea} = Board.answer_question(idea, @fredrik, "Why?", %{"deferred" => false})
    assert Enum.count(idea.transitions, &((&1.note || "") =~ "Why?")) == 1
  end
end
