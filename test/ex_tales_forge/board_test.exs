defmodule TalesForge.BoardTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.Board
  alias TalesForge.Board.Idea
  alias TalesForge.Collab
  alias TalesForge.Repo

  doctest TalesForge.Board

  @ada "ada@example.com"
  @bo "bo@example.com"

  defp idea!(title \\ "Brenna remembers regulars", founder \\ @ada) do
    {:ok, idea} = Board.create_idea(founder, %{"title" => title, "body" => "A sentence."})
    idea
  end

  defp age!(idea, days) do
    at =
      DateTime.utc_now()
      |> DateTime.add(-round(days * 86_400), :second)
      |> DateTime.truncate(:second)

    Repo.update_all(from(i in Idea, where: i.id == ^idea.id), set: [inserted_at: at])
    Board.get_idea!(idea.id)
  end

  defp refined!(idea) do
    {:ok, idea} = Board.move(idea, {:founder, @ada}, "refining")

    {:ok, idea} =
      Board.refine(idea, %{
        "details" => "Track visits per character.",
        "open_questions" => ["After how many visits?"],
        "rough_cost" => "S",
        "verdict" => "feasible"
      })

    idea
  end

  describe "ideas and votes" do
    test "a founder adds an idea; it starts in Ideas with its history" do
      idea = idea!()
      assert idea.column == "ideas"
      assert idea.author == @ada
      assert [%{to: "ideas", actor: @ada}] = idea.transitions
      assert {:error, %Ecto.Changeset{}} = Board.create_idea(@ada, %{"title" => ""})
    end

    test "one vote per founder: +1, change to -1, same again takes it back" do
      idea = idea!()
      {:ok, idea} = Board.vote(idea, @ada, 1)
      {:ok, idea} = Board.vote(idea, "BO@example.com", 1)
      assert Board.net_votes(idea) == 2
      {:ok, idea} = Board.vote(idea, @bo, -1)
      assert Board.net_votes(idea) == 0
      assert Board.vote_of(idea, @bo) == -1
      assert Board.downvoted?(idea)
      {:ok, idea} = Board.vote(idea, @bo, -1)
      assert Board.vote_of(idea, @bo) == nil
      assert Board.net_votes(idea) == 1
      assert {:error, _} = Board.vote(idea, @ada, 2)
    end

    test "the Ideas column is ranked by net votes with decay (the design's example)" do
      a = idea!("Idea A") |> age!(10)
      b = idea!("Idea B") |> age!(1)
      c = idea!("Idea C") |> age!(2)

      for f <- ~w(f1@x f2@x f3@x), do: {:ok, _} = Board.vote(a, f, 1)
      for f <- ~w(f1@x f2@x), do: {:ok, _} = Board.vote(b, f, 1)
      for f <- ~w(f1@x f2@x f3@x), do: {:ok, _} = Board.vote(c, f, 1)
      {:ok, _} = Board.vote(c, "f4@x", -1)

      ranked = Board.ranked_ideas()
      assert Enum.map(ranked, & &1.title) == ["Idea B", "Idea C", "Idea A"]
      assert ranked |> hd() |> Map.get(:score) |> Float.round(2) == 0.83
      assert MapSet.size(Board.pullable_ids()) == 3
    end
  end

  describe "moves and rules" do
    test "the happy path: founder → Case → founder OK → Bobby → Gentry → Done" do
      idea = idea!() |> refined!()
      assert Board.refined?(idea)
      {:ok, idea} = Board.move(idea, {:bot, :case}, "check")
      {:ok, idea} = Board.add_comment(idea, @bo, "Only after the second visit?")
      {:ok, idea} = Board.move(idea, {:founder, @bo}, "building", "Looks right")
      assert idea.column == "building"

      assert {:error, "Add the PR and playtest links first."} =
               Board.move(idea, {:bot, :bobby}, "done")

      {:ok, idea} =
        Board.add_link(idea, "bot:bobby", %{
          "kind" => "pr",
          "url" => "https://github.com/x/y/pull/1"
        })

      {:ok, idea} =
        Board.add_link(idea, "bot:bobby", %{"kind" => "playtest", "url" => "https://p.example/v1"})

      assert {:error, "Wait for Gentry's check first."} = Board.move(idea, {:bot, :bobby}, "done")
      {:ok, idea} = Board.add_comment(idea, "bot:gentry", Board.gentry_pass() <> ". All good.")
      {:ok, idea} = Board.move(idea, {:bot, :bobby}, "done")
      assert idea.column == "done"

      assert Enum.map(idea.transitions, &{&1.from, &1.to}) == [
               {nil, "ideas"},
               {"ideas", "refining"},
               {"refining", "check"},
               {"check", "building"},
               {"building", "done"}
             ]

      assert Enum.at(idea.transitions, 3).actor == @bo
      assert Enum.at(idea.transitions, 3).note == "Looks right"
    end

    test "no OK while any founder has a -1 vote" do
      idea = idea!() |> refined!()
      {:ok, idea} = Board.move(idea, {:bot, :case}, "check")
      {:ok, idea} = Board.vote(idea, @bo, -1)

      assert {:error, "A founder has voted -1 on this idea. Talk it through first."} =
               Board.move(idea, {:founder, @ada}, "building")

      {:ok, idea} = Board.vote(idea, @bo, -1)
      assert {:ok, %{column: "building"}} = Board.move(idea, {:founder, @ada}, "building")
    end

    test "Case needs a complete refinement and may only pull ideas with support" do
      idea = idea!()
      assert {:error, _} = Board.move(idea, {:bot, :case}, "refining")
      {:ok, idea} = Board.vote(idea, @ada, 1)
      assert {:ok, idea} = Board.move(idea, {:bot, :case}, "refining")
      assert {:error, msg} = Board.move(idea, {:bot, :case}, "check")
      assert msg =~ "refinement"
      assert {:error, _} = Board.refine(idea, %{"rough_cost" => "XL"})
      assert {:error, _} = Board.refine(idea, %{"verdict" => "maybe"})
      assert {:error, _} = Board.refine(idea, %{"open_questions" => "one"})
    end

    test "bots never OK, and votes close once building" do
      idea = idea!() |> refined!()
      {:ok, idea} = Board.move(idea, {:bot, :case}, "check")

      assert {:error, "Only a founder can move a card to Building."} =
               Board.move(idea, {:bot, :case}, "building")

      {:ok, idea} = Board.move(idea, {:founder, @ada}, "building")
      assert {:error, _} = Board.vote(idea, @ada, 1)
      assert {:error, _} = Board.refine(idea, %{"details" => "x"})
    end

    test "park and unpark" do
      idea = idea!()
      {:ok, idea} = Board.move(idea, {:founder, @ada}, "parked")
      {:ok, idea} = Board.move(idea, {:founder, @ada}, "ideas")
      assert idea.column == "ideas"
      assert {:error, "The card is already there."} = Board.move(idea, {:founder, @ada}, "ideas")
    end

    test "record_decision is set once" do
      idea = idea!()

      {:ok, idea} =
        Board.record_decision(idea, "2026-10-10-x", "abc123", "https://github.com/c/abc123")

      {:ok, idea} = Board.record_decision(idea, "other", "def456", "https://github.com/c/def456")
      assert idea.decision_sha == "abc123"
      assert [%{kind: "decision"}] = idea.links
    end

    test "board/1 groups every column" do
      idea!()
      board = Board.board()
      assert Map.keys(board) |> Enum.sort() == Enum.sort(Idea.columns())
      assert [_] = board["ideas"]
      assert Board.get_idea("nope") == nil
    end
  end

  describe "the Collab import" do
    @fixture Path.expand("../fixtures/tales_forge_docs", __DIR__)

    test "imports the open decisions once, with comments; the queue turns read-only" do
      {:ok, _} = TalesForge.Collab.Importer.import_from_path(@fixture)
      [d | _] = Collab.list_decisions()
      {:ok, _} = Collab.add_comment(d, "x@example.com", "An old comment")
      open = Enum.count(Collab.list_decisions(), &(&1.status in ~w(open discussing)))
      assert open > 0
      refute Board.collab_imported?()

      assert {:ok, ^open} = Board.import_collab()
      assert {:ok, 0} = Board.import_collab()
      assert Board.collab_imported?()

      imported = Repo.get_by!(Idea, collab_decision_id: d.id) |> Repo.preload(:comments)
      assert imported.title == d.title
      assert [%{body: "An old comment"}] = imported.comments
    end
  end
end
