defmodule TalesForge.Board.OutboxTest do
  use TalesForge.DataCase, async: false

  alias TalesForge.Board
  alias TalesForge.Board.{GitHubApp, Workers.LogDecision, Workers.Notify}

  doctest TalesForge.Board.Events
  doctest TalesForge.Board.Workers.Notify
  doctest TalesForge.Board.Workers.LogDecision

  @ada "ada@example.com"

  setup do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, conn.req_headers, body})
      handle(conn, body)
    end)

    Application.put_env(:ex_tales_forge, :board_req_options, plug: {Req.Test, __MODULE__})

    Application.put_env(:ex_tales_forge, :board_bots,
      case: [webhook_url: "https://case.example/hook", webhook_key: "case-key"],
      bobby: [webhook_url: "https://bobby.example/hook", webhook_key: "bobby-key"],
      gentry: []
    )

    on_exit(fn ->
      for k <- [:board_req_options, :board_bots, :github_app],
          do: Application.delete_env(:ex_tales_forge, k)
    end)

    :ok
  end

  # GitHub and the bots' webhooks, stubbed.
  defp handle(%{request_path: "/app/installations/" <> _} = conn, _),
    do: Req.Test.json(Plug.Conn.put_status(conn, 201), %{"token" => "inst-token"})

  defp handle(
         %{
           method: "GET",
           request_path: "/repos/whyse-ab/tales-forge-docs/contents/docs/decisions.md"
         } = conn,
         _
       ) do
    text =
      Process.get(:decisions_md) ||
        "---\nupdated: 2026-10-09\n---\n\n# Decision log\n\nIntro.\n\n## 2026-10-09: Old\n"

    Req.Test.json(conn, %{"content" => Base.encode64(text), "sha" => "blob1"})
  end

  defp handle(%{method: "PUT"} = conn, _),
    do: Req.Test.json(Plug.Conn.put_status(conn, 201), %{"commit" => %{"sha" => "c0ffee"}})

  defp handle(%{request_path: "/repos/whyse-ab/tales-forge-docs/commits"} = conn, _),
    do: Req.Test.json(conn, [%{"sha" => "already1"}])

  defp handle(conn, _), do: Req.Test.json(conn, %{"ok" => true})

  defp header(headers, name), do: headers |> List.keyfind(name, 0) |> elem(1)

  defp refined!(idea) do
    {:ok, idea} = Board.move(idea, {:founder, @ada}, "refining")

    {:ok, idea} =
      Board.refine(idea, %{
        "details" => "Track visits.",
        "open_questions" => [],
        "rough_cost" => "S",
        "verdict" => "feasible"
      })

    idea
  end

  defp github_app! do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    Application.put_env(:ex_tales_forge, :github_app,
      app_id: "123",
      installation_id: "456",
      private_key: pem
    )

    key
  end

  test "moving a card to Refining wakes Case with a signed POST" do
    {:ok, idea} = Board.create_idea(@ada, %{"title" => "Brenna remembers regulars"})
    {:ok, _} = Board.move(idea, {:founder, @ada}, "refining")

    assert_receive {:request, "POST", "/hook", headers, body}
    payload = Jason.decode!(body)
    assert payload["event"] == "idea.to_refining"
    assert payload["bot"] == "case"
    assert payload["idea"]["id"] == idea.id
    assert payload["transition"] == %{"from" => "ideas", "to" => "refining", "actor" => @ada}
    assert header(headers, "authorization") == "Bearer case-key"
    assert header(headers, "x-board-delivery") == payload["delivery_id"]
    ts = header(headers, "x-board-timestamp")
    assert header(headers, "x-board-signature") == Notify.signature("case-key", ts, body)
  end

  test "a bot without a webhook is skipped; a failing webhook is retried" do
    assert {:cancel, _} =
             perform_job(Notify, %{
               "bot" => "gentry",
               "event" => "x",
               "delivery_id" => "d",
               "payload" => %{}
             })

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "no") end)

    assert {:error, "webhook answered 500"} =
             perform_job(Notify, %{
               "bot" => "case",
               "event" => "x",
               "delivery_id" => "d",
               "payload" => %{}
             })

    assert Notify.backoff(%Oban.Job{attempt: 1}) == 60
    assert Notify.backoff(%Oban.Job{attempt: 20}) == 4 * 3600
  end

  test "a @mention wakes that bot" do
    {:ok, idea} = Board.create_idea(@ada, %{"title" => "Brenna remembers regulars"})
    {:ok, _} = Board.add_comment(idea, @ada, "@bobby how big is this?")
    assert_receive {:request, "POST", "/hook", headers, body}
    assert header(headers, "authorization") == "Bearer bobby-key"
    assert Jason.decode!(body)["comment"]["body"] =~ "how big"
  end

  test "the founder OK writes the decision log entry once and wakes Bobby" do
    key = github_app!()

    {:ok, idea} =
      Board.create_idea(@ada, %{
        "title" => "Brenna remembers regulars",
        "body" => "She greets you by name."
      })

    idea = refined!(idea)
    {:ok, idea} = Board.move(idea, {:bot, :case}, "check")
    {:ok, _} = Board.move(idea, {:founder, "bo@example.com"}, "building")

    assert_receive {:request, "POST", "/app/installations/456/access_tokens", headers, _}
    "Bearer " <> jwt = header(headers, "authorization")
    [h, c, s] = String.split(jwt, ".")

    assert :public_key.verify(
             h <> "." <> c,
             :sha256,
             Base.url_decode64!(s, padding: false),
             public(key)
           )

    assert %{"iss" => "123"} = c |> Base.url_decode64!(padding: false) |> Jason.decode!()

    assert_receive {:request, "PUT",
                    "/repos/whyse-ab/tales-forge-docs/contents/docs/decisions.md", _, put}

    put = Jason.decode!(put)
    assert put["sha"] == "blob1"
    assert put["branch"] == "main"
    text = Base.decode64!(put["content"])
    assert text =~ "updated: #{Date.utc_today()}"
    assert text =~ "## #{Date.utc_today()}: Brenna remembers regulars\n"
    assert text =~ "OK by" or put["message"] =~ "OK by bo@example.com"
    assert text =~ "She greets you by name."
    assert text =~ "<!-- board:idea:#{idea.id} -->"
    [new, old] = String.split(text, "## ", parts: 3) |> tl()
    assert new =~ "Brenna" and old =~ "Old"

    idea = Board.get_idea!(idea.id)
    assert idea.decision_sha == "c0ffee"
    assert Enum.any?(idea.links, &(&1.kind == "decision" and &1.url =~ "c0ffee"))
    hooks = drain_hooks()
    assert "Bearer bobby-key" in hooks

    # Idempotent: a second run commits nothing.
    assert :ok = perform_job(LogDecision, %{"idea_id" => idea.id})
    refute_receive {:request, "PUT", _, _, _}
  end

  test "the marker already in the file: no commit, the latest commit is recorded" do
    github_app!()
    {:ok, idea} = Board.create_idea(@ada, %{"title" => "Brenna remembers regulars"})
    Process.put(:decisions_md, "# Log\n\n## X\n\n" <> LogDecision.marker(idea) <> "\n")
    assert :ok = perform_job(LogDecision, %{"idea_id" => idea.id})
    refute_receive {:request, "PUT", _, _, _}
    assert Board.get_idea!(idea.id).decision_sha == "already1"
  end

  test "without the GitHub App the card says the entry wasn't written" do
    {:ok, idea} = Board.create_idea(@ada, %{"title" => "Brenna remembers regulars"})

    assert {:cancel, :github_app_not_configured} =
             perform_job(LogDecision, %{"idea_id" => idea.id})

    assert [%{author: "bot:board", body: body}] = Board.get_idea!(idea.id).comments
    assert body =~ "GitHub App"
    assert GitHubApp.token() == {:error, :not_configured}
  end

  test "insert_entry puts the entry first and bumps updated" do
    assert LogDecision.insert_entry(
             "---\nupdated: 2026-10-09\n---\n\n# Log\n\n## Old\n",
             "## New\n",
             ~D[2026-10-10]
           ) ==
             "---\nupdated: 2026-10-10\n---\n\n# Log\n\n## New\n\n## Old\n"

    assert LogDecision.insert_entry("# Log\n", "## New\n", ~D[2026-10-10]) == "# Log\n\n## New\n"
  end

  defp drain_hooks(acc \\ []) do
    receive do
      {:request, "POST", "/hook", headers, _} ->
        drain_hooks([header(headers, "authorization") | acc])
    after
      0 -> acc
    end
  end

  defp public({:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _}), do: {:RSAPublicKey, n, e}

  defp perform_job(worker, args),
    do: Oban.Testing.perform_job(worker, args, repo: TalesForge.Repo)
end
