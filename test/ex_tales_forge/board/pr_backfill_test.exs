defmodule TalesForge.Board.PrBackfillTest do
  @moduledoc """
  An open normal-lane PR on a Building card waits for approval, also when it
  came as a plain `pr` link (card 6d08cf7e). A merged, closed or fast-lane PR
  gets no Approve.
  """
  use TalesForge.DataCase, async: false
  use Oban.Testing, repo: TalesForge.Repo

  alias TalesForge.Board
  alias TalesForge.Board.Workers.PrBackfill

  @ada "ada@example.com"
  @lanes "[admin]\nlib/ex_tales_forge/board/\n[game]\nlib/ex_tales_forge/game/\n"

  # GitHub: PR 1 open (game file), PR 2 merged, PR 3 closed, PR 4 open
  # (admin files only), PR 5 open with a rename from a game file.
  # `down: true` makes GitHub answer 503.
  defp github!(opts \\ []) do
    Application.put_env(:ex_tales_forge, :pr_feed_token, "feed-token")
    Application.put_env(:ex_tales_forge, :board_req_options, plug: {Req.Test, __MODULE__})
    Req.Test.stub(__MODULE__, &answer(&1, opts))

    on_exit(fn ->
      Application.delete_env(:ex_tales_forge, :pr_feed_token)
      Application.delete_env(:ex_tales_forge, :board_req_options)
    end)
  end

  defp answer(conn, opts) do
    path = conn.request_path

    cond do
      opts[:down] ->
        Plug.Conn.send_resp(conn, 503, "down")

      String.ends_with?(path, "/contents/.github/deploy-lanes.txt") ->
        Req.Test.json(conn, %{"content" => Base.encode64(@lanes)})

      match = Regex.run(~r{/pulls/(\d+)/files$}, path) ->
        Req.Test.json(conn, files(List.last(match)))

      match = Regex.run(~r{/pulls/(\d+)$}, path) ->
        Req.Test.json(conn, pull(List.last(match)))
    end
  end

  defp pull(n) do
    {state, merged} =
      case n do
        "2" -> {"closed", true}
        "3" -> {"closed", false}
        _ -> {"open", false}
      end

    %{
      "state" => state,
      "merged" => merged,
      "head" => %{"sha" => "head#{n}abc"},
      "html_url" => "https://github.com/whyse-ab/ex-tales-forge/pull/#{n}"
    }
  end

  defp files("4"), do: [%{"filename" => "lib/ex_tales_forge/board/api.ex"}]

  defp files("5"),
    do: [
      %{
        "filename" => "lib/ex_tales_forge/board/turn.ex",
        "previous_filename" => "lib/ex_tales_forge/game/turn.ex"
      }
    ]

  defp files(_), do: [%{"filename" => "lib/ex_tales_forge/game/turn.ex"}]

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

  test "an open normal-lane PR link waits for approval; merged, closed and fast-lane PRs do not" do
    github!()
    open = building!("Open", 1)
    merged = building!("Merged", 2)
    closed = building!("Closed", 3)
    fast = building!("Fast lane", 4)
    renamed = building!("Renamed", 5)
    no_pr = building!("No PR", nil)

    assert {:ok, marked} = PrBackfill.run()
    assert Enum.sort(marked) == Enum.sort([open.id, renamed.id])

    card = Board.get_idea!(open.id)
    assert {card.pr_number, card.pr_head_sha} == {1, "head1abc"}
    assert card.pr_url == "https://github.com/whyse-ab/ex-tales-forge/pull/1"
    assert Board.pr_waiting?(card)
    assert Board.facts(card).pr == :awaiting
    last = List.last(card.transitions)
    assert {last.actor, last.note} == {"bot:board", "PR #1 (head1ab) waits for a founder's OK."}

    for idea <- [merged, closed, fast, no_pr] do
      card = Board.get_idea!(idea.id)
      assert card.pr_number == nil
      refute Board.pr_waiting?(card)
    end

    # Idempotent: a second run marks nothing and writes no new line.
    assert {:ok, []} = PrBackfill.run()
    assert length(Board.get_idea!(open.id).transitions) == length(card.transitions)
  end

  test "Approve works on a backfilled PR, and the badge goes away" do
    github!()
    idea = building!("Open", 1)
    assert {:ok, [_]} = PrBackfill.run()

    assert {:ok, card} = Board.answer_pr(Board.get_idea!(idea.id), @ada, :approve, nil)
    assert [%{decision: "approved", pr_number: 1, head_sha: "head1abc"}] = card.approvals
    refute Board.pr_waiting?(card)
  end

  test "a PR from link_pr/1 keeps its sha and note; the job leaves it" do
    github!()

    {:ok, idea} =
      Board.link_pr(%{
        "number" => 1,
        "url" => "https://github.com/whyse-ab/ex-tales-forge/pull/1",
        "head_sha" => "own1234",
        "player_note" => "Nothing changes for players.",
        "title" => "Linked"
      })

    assert {:ok, []} = PrBackfill.run()
    card = Board.get_idea!(idea.id)
    assert {card.pr_head_sha, card.player_note} == {"own1234", "Nothing changes for players."}
  end

  test "GitHub down or no token: nothing changes, the job fails so Oban tries again" do
    idea = building!("Open", 1)

    assert {:error, "The board cannot read GitHub now (no GITHUB_FEED_TOKEN)."} =
             PrBackfill.run()

    github!(down: true)
    assert {:error, "GitHub did not give .github/deploy-lanes.txt" <> _} = PrBackfill.run()
    assert Board.get_idea!(idea.id).pr_number == nil

    github!()
    assert {:ok, [_]} = PrBackfill.run()
  end

  test "mark_pr_waiting/4 accepts only a card in Building" do
    {:ok, idea} = Board.create_idea(@ada, %{"title" => "In Ideas"})

    assert {:error, "A PR waits for approval on a card in Building." <> _} =
             Board.mark_pr_waiting(idea, 1, "https://github.com/x/y/pull/1", "abc")
  end

  test "off production the job and the boot hook do nothing; on, a PR link queues a run" do
    github!()
    idea = building!("Open", 1)
    assert :ok = PrBackfill.schedule_on_boot()
    assert :ok = perform_job(PrBackfill, %{})
    assert Board.get_idea!(idea.id).pr_number == nil

    Application.put_env(:ex_tales_forge, :board_pr_backfill_anywhere, true)
    on_exit(fn -> Application.delete_env(:ex_tales_forge, :board_pr_backfill_anywhere) end)

    # Oban runs inline in tests: the run that the new PR link queues marks both cards.
    another = building!("Another", 6)
    assert Board.pr_waiting?(Board.get_idea!(idea.id))
    assert Board.pr_waiting?(Board.get_idea!(another.id))
  end
end
