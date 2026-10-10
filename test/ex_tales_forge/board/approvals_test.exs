defmodule TalesForge.Board.ApprovalsTest do
  @moduledoc "Merge approvals on the board (decision 2026-10-10)."
  use TalesForge.DataCase, async: false

  alias TalesForge.Board
  alias TalesForge.Board.{Api, Workers.Notify}

  @pr %{
    "number" => 125,
    "url" => "https://github.com/whyse-ab/ex-tales-forge/pull/125",
    "head_sha" => "abc1234def5678",
    "player_note" => "Brenna greets returning players by name.",
    "title" => "Brenna remembers regulars"
  }

  setup do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:hook, conn.req_headers, body})
      Req.Test.json(conn, %{"ok" => true})
    end)

    Application.put_env(:ex_tales_forge, :board_req_options, plug: {Req.Test, __MODULE__})

    Application.put_env(:ex_tales_forge, :board_bots,
      bobby: [webhook_url: "https://bobby.example/hook", webhook_key: "bobby-key"]
    )

    on_exit(fn ->
      Application.delete_env(:ex_tales_forge, :board_req_options)
      Application.delete_env(:ex_tales_forge, :board_bots)
    end)

    :ok
  end

  defp header(headers, name), do: headers |> List.keyfind(name, 0) |> elem(1)

  describe "Bobby links a PR (POST /internal/board/prs)" do
    test "only Bobby; the card is made and stays in Building with the PR waiting for approval" do
      assert {403, _} = Api.handle(:pr, :case, @pr)
      assert {403, _} = Api.handle(:pr, :gentry, @pr)

      assert {200, card} = Api.handle(:pr, :bobby, @pr)
      assert card["column"] == "building"
      assert card["author"] == "bot:bobby"

      assert card["pr"] == %{
               "number" => 125,
               "url" => @pr["url"],
               "head_sha" => "abc1234def5678",
               "player_note" => "Brenna greets returning players by name."
             }

      assert [%{"kind" => "pr", "url" => "https://github.com/whyse-ab/ex-tales-forge/pull/125"}] =
               card["links"]

      assert List.last(card["history"])["note"] =~ "PR #125 (abc1234) waits for a founder's OK"

      assert Enum.map(card["history"], &{&1["from"], &1["to"]}) == [
               {nil, "building"},
               {"building", "building"}
             ]

      assert Board.pr_waiting?(Board.get_idea!(card["id"]))
    end

    test "the same PR again updates the card instead of making a second one; an existing card can be named" do
      {200, card} = Api.handle(:pr, :bobby, @pr)
      {200, again} = Api.handle(:pr, :bobby, %{@pr | "head_sha" => "fff0000"})
      assert again["id"] == card["id"]
      assert again["pr"]["head_sha"] == "fff0000"
      assert length(again["links"]) == 1

      {:ok, idea} = Board.create_idea("ada@example.com", %{"title" => "Fishing"})
      named = Map.merge(@pr, %{"number" => 126, "idea_id" => idea.id})

      assert {422, %{"error" => "Bobby links a PR to a card in Building. This card is in Ideas."}} =
               Api.handle(:pr, :bobby, named)

      {:ok, idea} = Board.vote(idea, "ada@example.com", 1)
      {:ok, idea} = Board.move(idea, {:founder, "ada@example.com"}, "refining")

      {:ok, _} =
        Board.refine(idea, %{"open_questions" => [], "rough_cost" => "S", "verdict" => "feasible"})

      {:ok, idea} = Board.move(idea, {:bot, :case}, "check")
      {:ok, _} = Board.move(idea, {:founder, "ada@example.com"}, "building")
      assert {200, %{"id" => id, "column" => "building"}} = Api.handle(:pr, :bobby, named)
      assert id == idea.id
    end

    test "missing fields are refused" do
      for key <- ~w(number url head_sha player_note) do
        assert {422, %{"error" => _}} = Api.handle(:pr, :bobby, Map.delete(@pr, key)), key
      end
    end
  end

  describe "founders answer the PR" do
    setup do
      {200, card} = Api.handle(:pr, :bobby, @pr)
      flush()
      {:ok, idea: Board.get_idea!(card["id"])}
    end

    defp flush do
      receive do
        {:hook, _, _} -> flush()
      after
        0 -> :ok
      end
    end

    test "Approve records who, when, PR and sha, keeps the card in Building and wakes Bobby with pr.approved",
         %{idea: idea} do
      assert {:ok, idea} = Board.answer_pr(idea, "Fredrik@Whyse.se", :approve, "Ship it")
      assert idea.column == "building"
      refute Board.pr_waiting?(idea)
      assert [a] = idea.approvals

      assert {a.decision, a.founder, a.pr_number, a.head_sha, a.comment} ==
               {"approved", "fredrik@whyse.se", 125, "abc1234def5678", "Ship it"}

      assert %DateTime{} = a.inserted_at
      assert List.last(idea.transitions).note == "Approved PR #125 (abc1234): Ship it"

      assert_receive {:hook, headers, body}
      assert header(headers, "x-board-event") == "pr.approved"
      assert header(headers, "authorization") == "Bearer bobby-key"

      assert header(headers, "x-board-signature") ==
               Notify.signature("bobby-key", header(headers, "x-board-timestamp"), body)

      payload = Jason.decode!(body)
      assert payload["event"] == "pr.approved"
      assert payload["bot"] == "bobby"

      assert payload["pr"] == %{
               "number" => 125,
               "url" => @pr["url"],
               "head_sha" => "abc1234def5678"
             }

      assert payload["approver"] == "fredrik@whyse.se"
      assert payload["comment"] == "Ship it"
      assert payload["idea"]["id"] == idea.id

      assert payload["transition"] == %{
               "from" => "building",
               "to" => "building",
               "actor" => "fredrik@whyse.se"
             }
    end

    test "Request changes keeps the card in Building and sends pr.changes_requested", %{
      idea: idea
    } do
      assert {:ok, idea} =
               Board.answer_pr(idea, "bo@example.com", :request_changes, "Say her name twice")

      assert idea.column == "building"
      assert Board.pr_waiting?(idea)
      assert [%{decision: "changes_requested", comment: "Say her name twice"}] = idea.approvals
      assert List.last(idea.transitions).note =~ "Changes requested on PR #125"

      assert_receive {:hook, headers, body}
      assert header(headers, "x-board-event") == "pr.changes_requested"
      payload = Jason.decode!(body)
      assert payload["comment"] == "Say her name twice"
      assert payload["approver"] == "bo@example.com"
      assert payload["pr"]["number"] == 125
    end

    test "permissions: bots can't answer, only while a PR waits, only with a PR; a new sha keeps the Approve",
         %{idea: idea} do
      assert {:error, "Only a founder can answer a PR."} =
               Board.answer_pr(idea, "bot:bobby", :approve, "")

      assert {:error, "Founder check is for the refined idea." <> _} =
               Board.move(idea, {:bot, :bobby}, "check")

      assert {:ok, _} = Board.answer_pr(idea, "ada@example.com", :request_changes, "Let's talk")
      assert {:ok, idea} = Board.answer_pr(idea, "ada@example.com", :approve, "")
      assert idea.column == "building"

      assert {:error, "No PR waits for approval on this card."} =
               Board.answer_pr(idea, "ada@example.com", :approve, "")

      {:ok, idea} = Board.link_pr(%{@pr | "head_sha" => "beef000"})
      refute Board.pr_waiting?(idea)
      assert Board.facts(idea).pr == :approved

      {:ok, plain} = Board.create_idea("ada@example.com", %{"title" => "No PR"})

      assert {:error, "No PR waits on this card."} =
               Board.answer_pr(plain, "ada@example.com", :approve, "")

      refute_receive {:hook, _, ["pr.approved" | _]}
    end
  end

  describe "approve once: Bobby links the same PR again (decision 2026-10-10)" do
    setup do
      {200, card} = Api.handle(:pr, :bobby, @pr)
      flush_hooks()
      {:ok, idea: Board.get_idea!(card["id"])}
    end

    defp flush_hooks do
      receive do
        {:hook, _, _} -> flush_hooks()
      after
        0 -> :ok
      end
    end

    defp relink(sha, extra \\ %{}),
      do: Api.handle(:pr, :bobby, @pr |> Map.put("head_sha", sha) |> Map.merge(extra))

    defp notes(idea), do: Enum.map(Board.get_idea!(idea.id).transitions, & &1.note)

    test "before any answer: the new sha, one approval request in the history", %{idea: idea} do
      assert {200, card} = relink("bbb2222ffff")
      assert card["pr"]["head_sha"] == "bbb2222ffff"
      assert List.last(card["history"])["note"] == "New commit bbb2222 on PR #125."
      assert Enum.count(notes(idea), &(&1 =~ "waits for a founder's OK")) == 1
      assert Board.pr_waiting?(Board.get_idea!(idea.id))
    end

    test "after Approve: a new sha keeps the approval and wakes Bobby with the newest head",
         %{idea: idea} do
      {:ok, _} = Board.answer_pr(idea, "fredrik@whyse.se", :approve, nil)
      flush_hooks()

      assert {200, card} = relink("ccc3333eeee")
      idea = Board.get_idea!(idea.id)
      refute Board.pr_waiting?(idea)
      assert Board.facts(idea).pr == :approved

      assert List.last(card["history"])["note"] ==
               "New commit ccc3333 after approval; approval kept."

      assert [_, kept] = Enum.sort_by(idea.approvals, & &1.inserted_at, DateTime)

      assert {kept.decision, kept.founder, kept.head_sha} ==
               {"approved", "fredrik@whyse.se", "ccc3333eeee"}

      assert_receive {:hook, headers, body}
      assert header(headers, "x-board-event") == "pr.approved"
      assert Jason.decode!(body) |> inspect() =~ "ccc3333eeee"
    end

    test "player_change: true asks the founders again", %{idea: idea} do
      {:ok, _} = Board.answer_pr(idea, "fredrik@whyse.se", :approve, nil)
      flush_hooks()

      assert {200, card} = relink("ddd4444", %{"player_change" => true})
      assert Board.pr_waiting?(Board.get_idea!(idea.id))
      assert List.last(card["history"])["note"] =~ "PR #125 (ddd4444) waits for a founder's OK"
      refute_receive {:hook, _, _}
    end

    test "after Request changes: the next link asks again", %{idea: idea} do
      {:ok, _} = Board.answer_pr(idea, "fredrik@whyse.se", :request_changes, "Shorter text")
      assert {200, _} = relink("eee5555")
      assert Board.pr_waiting?(Board.get_idea!(idea.id))
    end
  end
end
