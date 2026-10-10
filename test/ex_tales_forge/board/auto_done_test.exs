defmodule TalesForge.Board.AutoDoneTest do
  @moduledoc "The board moves Building cards to Done when their PR is in the prod release."
  use TalesForge.DataCase, async: false

  alias TalesForge.Board
  use Oban.Testing, repo: TalesForge.Repo

  alias TalesForge.Board.Workers.AutoDone

  doctest AutoDone

  @ada "ada@example.com"

  # GitHub: PR n merged as m<n>; m1 and m2 are in the running release run9,
  # m3 is not. `down: true` makes GitHub answer 503.
  defp github!(opts \\ []) do
    Application.put_env(:ex_tales_forge, :pr_feed_token, "feed-token")
    Application.put_env(:ex_tales_forge, :board_req_options, plug: {Req.Test, __MODULE__})
    System.put_env("GIT_SHA", "run9")
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:github, conn.request_path})

      cond do
        opts[:down] ->
          Plug.Conn.send_resp(conn, 503, "down")

        match = Regex.run(~r{/pulls/(\d+)$}, conn.request_path) ->
          Req.Test.json(conn, %{"merged" => true, "merge_commit_sha" => "m#{List.last(match)}"})

        String.ends_with?(conn.request_path, "/compare/m3...run9") ->
          Req.Test.json(conn, %{"status" => "behind"})

        String.contains?(conn.request_path, "/compare/") ->
          Req.Test.json(conn, %{"status" => "ahead"})
      end
    end)

    on_exit(fn ->
      Application.delete_env(:ex_tales_forge, :pr_feed_token)
      Application.delete_env(:ex_tales_forge, :board_req_options)
      System.delete_env("GIT_SHA")
    end)
  end

  defp building!(title, pr) do
    {:ok, idea} = Board.create_idea(@ada, %{"title" => title})
    {:ok, idea} = Board.vote(idea, @ada, 1)
    {:ok, idea} = Board.move(idea, {:founder, @ada}, "refining")

    {:ok, idea} =
      Board.refine(idea, %{"open_questions" => [], "rough_cost" => "S", "verdict" => "feasible"})

    {:ok, idea} = Board.move(idea, {:bot, :case}, "check")
    {:ok, idea} = Board.move(idea, {:founder, @ada}, "building")

    if pr do
      {:ok, idea} =
        Board.add_link(idea, "bot:bobby", %{
          "kind" => "pr",
          "url" => "https://github.com/whyse-ab/ex-tales-forge/pull/#{pr}"
        })

      idea
    else
      idea
    end
  end

  test "moves exactly the Building cards whose PR is in the release, as bot:board, once" do
    github!()
    in1 = building!("In release", 1)
    in2 = building!("Also in", 2)
    later = building!("Not yet", 3)
    no_pr = building!("No PR", nil)

    assert {:ok, moved} = AutoDone.run()
    assert Enum.sort(moved) == Enum.sort([in1.id, in2.id])

    done = Board.get_idea!(in1.id)
    assert done.column == "done"
    last = List.last(done.transitions)
    assert {last.from, last.to, last.actor} == {"building", "done", "bot:board"}
    assert last.note == "PR #1 is in the prod release run9. The board moved the card to Done."

    assert Board.get_idea!(later.id).column == "building"
    assert Board.get_idea!(no_pr.id).column == "building"

    # Idempotent: a second run moves nothing and writes no new move.
    assert {:ok, []} = AutoDone.run()
    assert length(Board.get_idea!(in1.id).transitions) == length(done.transitions)
  end

  test "GitHub down: nothing moves, the job fails so Oban tries again" do
    github!(down: true)
    card = building!("In release", 1)

    assert {:error, "GitHub did not answer for PR #1. Try again later."} = AutoDone.run()
    assert Board.get_idea!(card.id).column == "building"

    github!()
    assert {:ok, [_]} = AutoDone.run()
    assert Board.get_idea!(card.id).column == "done"
  end

  test "no GIT_SHA: nothing moves, try again later" do
    github!()
    card = building!("In release", 1)
    System.delete_env("GIT_SHA")
    assert {:error, "The board cannot see the prod release" <> _} = AutoDone.run()
    assert Board.get_idea!(card.id).column == "building"
  end

  test "off production the job and the boot hook do nothing; backoff doubles up to 4 h" do
    github!()
    card = building!("In release", 1)
    assert :ok = AutoDone.schedule_on_boot()
    assert :ok = perform_job(AutoDone, %{})
    assert Board.get_idea!(card.id).column == "building"
    assert AutoDone.backoff(%Oban.Job{attempt: 1}) == 60
    assert AutoDone.backoff(%Oban.Job{attempt: 20}) == 4 * 3600
  end

  describe "a PR link added after the deploy (card b18fc8dc)" do
    setup do
      Application.put_env(:ex_tales_forge, :board_auto_done_anywhere, true)
      on_exit(fn -> Application.delete_env(:ex_tales_forge, :board_auto_done_anywhere) end)
    end

    test "the link queues a new run and the card moves to Done without a boot" do
      github!()
      card = building!("Linked late", nil)
      assert Board.get_idea!(card.id).column == "building"

      {:ok, _} =
        Board.add_link(card, "bot:bobby", %{
          "kind" => "pr",
          "url" => "https://github.com/whyse-ab/ex-tales-forge/pull/1"
        })

      done = Board.get_idea!(card.id)
      assert done.column == "done"
      assert List.last(done.transitions).actor == "bot:board"
    end

    test "a PR that is not in the release yet keeps the card in Building" do
      github!()
      card = building!("Linked late", nil)

      {:ok, _} =
        Board.add_link(card, "bot:bobby", %{
          "kind" => "pr",
          "url" => "https://github.com/whyse-ab/ex-tales-forge/pull/3"
        })

      assert Board.get_idea!(card.id).column == "building"
    end

    test "a link that is not a PR queues no run" do
      github!()
      card = building!("Doc only", nil)

      {:ok, _} =
        Board.add_link(card, "bot:bobby", %{"kind" => "doc", "url" => "https://x.test/d"})

      refute_received {:github, _}
      assert Board.get_idea!(card.id).column == "building"
    end
  end

  test "Done wakes no bot" do
    assert TalesForge.Board.Transitions.wakes("building", "done") == [:founders]
    assert TalesForge.Board.Events.bots(:idea_to_done, %{}) == []
  end
end
