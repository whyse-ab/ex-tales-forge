defmodule TalesForge.PrFeedTest do
  # Touches app env (feed token, peer token, app name) and the shared ETS table.
  use ExUnit.Case, async: false

  # The poller logs a warning when GitHub is down; keep test output clean.
  @moduletag :capture_log

  import TalesForge.PrFeedFixtures

  alias TalesForge.PrFeed
  alias TalesForge.PrFeed.GitHub
  alias TalesForge.PrFeed.Poller
  alias TalesForge.PrFeed.Versions

  doctest TalesForge.PrFeed
  doctest TalesForge.PrFeed.Parse
  doctest TalesForge.PrFeed.Deploys
  doctest TalesForge.PrFeed.GitHub
  doctest TalesForge.PrFeed.Versions
  doctest TalesForge.PrFeed.Pace

  @now ~U[2026-10-09 12:00:00Z]

  setup do
    on_exit(fn ->
      Application.put_env(:ex_tales_forge, :pr_feed_token, nil)
      Application.delete_env(:ex_tales_forge, :costs_peer)
      Application.delete_env(:ex_tales_forge, :app_name)
      System.delete_env("GIT_SHA")
      :ets.delete(Poller, :snapshot)
    end)

    :ok
  end

  defp put_token, do: Application.put_env(:ex_tales_forge, :pr_feed_token, "feed-token")

  # GitHub stub answering each resource from `answers` (resource => fun(conn)).
  defp stub_github(answers) do
    Req.Test.stub(GitHub, fn conn ->
      resource =
        cond do
          String.ends_with?(conn.request_path, "/pulls") -> :pulls
          String.ends_with?(conn.request_path, "/commits") -> :main
          String.ends_with?(conn.request_path, "/runs") -> :ci
        end

      Map.fetch!(answers, resource).(conn)
    end)
  end

  defp json(body, etag \\ nil) do
    fn conn ->
      conn = if etag, do: Plug.Conn.put_resp_header(conn, "etag", etag), else: conn
      Req.Test.json(conn, body)
    end
  end

  describe "not configured" do
    test "no token (unset or blank): nothing is fetched, status :not_configured" do
      Req.Test.stub(GitHub, fn _conn -> flunk("GitHub must not be called without a token") end)

      assert {%{status: :not_configured, items: []}, %{}} = Poller.poll(%{}, @now)
      assert GitHub.fetch(:pulls) == {:error, :not_configured}

      Application.put_env(:ex_tales_forge, :pr_feed_token, "  ")
      refute PrFeed.configured?()
      assert {%{status: :not_configured}, _} = Poller.poll(%{}, @now)
    end

    test "before any poll the snapshot is :not_configured without a token, :loading with one" do
      assert PrFeed.snapshot().status == :not_configured
      put_token()
      assert PrFeed.snapshot().status == :loading
    end
  end

  describe "GitHub down" do
    setup do
      put_token()
      :ok
    end

    test "unreachable: :unavailable, never raises" do
      Req.Test.stub(GitHub, &Req.Test.transport_error(&1, :econnrefused))
      assert {%{status: :unavailable, items: []}, _cache} = Poller.poll(%{}, @now)
    end

    test "an error status (e.g. a revoked token's 401 or a 502) is :unavailable" do
      for status <- [401, 403, 502] do
        Req.Test.stub(GitHub, &Plug.Conn.send_resp(&1, status, "nope"))
        assert GitHub.fetch(:pulls) == {:error, {:http_status, status}}
        assert {%{status: :unavailable}, _} = Poller.poll(%{}, @now)
      end
    end

    test "CI and main's commits failing only blank out CI and deploy status" do
      stub_github(%{
        pulls: json([pull(5, state: :open), pull(4, state: :merged)]),
        ci: &Plug.Conn.send_resp(&1, 500, ""),
        main: &Req.Test.transport_error(&1, :timeout)
      })

      {snapshot, cache} = Poller.poll(%{}, @now)
      assert snapshot.status == :ok
      assert [%{number: 5, ci: nil}, %{number: 4, deployed: deployed}] = snapshot.items
      assert deployed == %{playtest: :unknown, production: :unknown}
      assert Map.keys(cache) == [{:pulls, 1}]
      assert snapshot.pace == nil
    end
  end

  describe "a full poll" do
    setup do
      put_token()
      Application.put_env(:ex_tales_forge, :costs_peer, token: "peer-token")
      Application.put_env(:ex_tales_forge, :app_name, "tales-forge-playtest")
      System.put_env("GIT_SHA", "3333333")
      :ok
    end

    test "parses pull requests, CI, main and the running commits into a snapshot" do
      stub_github(%{
        pulls:
          json([
            pull(6, state: :open, head: "h6", at: "2026-10-09T11:00:00Z"),
            pull(5, state: :open, head: "h5", draft: true, at: "2026-10-09T10:30:00Z"),
            pull(4, state: :merged, at: "2026-10-09T10:00:00Z"),
            pull(3, state: :merged, at: "2026-10-08T09:00:00Z"),
            pull(2, state: :closed, at: "2026-10-07T09:00:00Z"),
            pull(1, state: :merged, at: "2026-10-02T09:00:00Z")
          ]),
        ci: json(runs([{"h6", "completed", "success"}, {"h5", "in_progress", nil}])),
        main: json(commits(~w(4444444 3333333 abcdef0 1111111)))
      })

      Req.Test.stub(Versions, fn conn ->
        assert conn.host == "tales-forge.fly.dev"
        assert conn.request_path == "/internal/version"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer peer-token"]
        Req.Test.json(conn, %{"app" => "production", "git_sha" => "1111111"})
      end)

      {snapshot, _cache} = Poller.poll(%{}, @now)

      assert snapshot.status == :ok
      assert snapshot.fetched_at == @now
      # Midnight Stockholm = 2026-10-08 22:00Z; Monday 2026-10-05 00:00 Stockholm.
      assert {snapshot.merged_today, snapshot.merged_week} == {1, 2}

      assert Enum.map(snapshot.items, &{&1.number, &1.state}) ==
               [{6, :open}, {5, :open}, {4, :merged}, {3, :merged}, {2, :closed}, {1, :merged}]

      [six, five, four, three, two, one] = snapshot.items
      assert {six.ci, five.ci, five.draft} == {:passed, :running, true}
      assert six.author == "bobby-bot"
      assert four.deployed == %{playtest: :pending, production: :pending}
      assert three.deployed == %{playtest: :deployed, production: :pending}
      assert one.deployed == %{playtest: :deployed, production: :deployed}
      assert two.deployed == %{playtest: :not_merged, production: :not_merged}
      assert two.ci == nil
    end

    test "counts every pull request and commit, page by page, into the pace" do
      test_pid = self()
      # 100 on page 1 (so page 2 is asked for) and 5 on page 2; 3 of them open.
      page1 = for n <- 105..6//-1, do: pull(n, state: :merged, at: "2026-10-09T09:00:00Z")

      page2 =
        for n <- 5..1//-1,
            do:
              pull(n,
                state: if(n <= 3, do: :open, else: :closed),
                created: "2026-10-07T09:00:00Z",
                at: "2026-10-07T09:00:00Z"
              )

      main1 = for n <- 1..100, do: "c#{n}"

      Req.Test.stub(GitHub, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        page = conn.query_params["page"] || "1"
        send(test_pid, {:page, conn.request_path, page})

        case {Path.basename(conn.request_path), page} do
          {"pulls", "1"} -> Req.Test.json(conn, page1)
          {"pulls", "2"} -> Req.Test.json(conn, page2)
          {"commits", "1"} -> Req.Test.json(conn, commits(main1, "2026-10-08T10:00:00Z"))
          {"commits", "2"} -> Req.Test.json(conn, commits(~w(d1 d2), "2026-07-02T10:00:00Z"))
          {"runs", _} -> Req.Test.json(conn, runs([]))
        end
      end)

      Req.Test.stub(Versions, &Plug.Conn.send_resp(&1, 404, ""))

      {snapshot, cache} = Poller.poll(%{}, @now)

      assert_received {:page, "/repos/whyse-ab/ex-tales-forge/pulls", "2"}
      assert_received {:page, "/repos/whyse-ab/ex-tales-forge/commits", "2"}
      refute_received {:page, _path, "3"}
      assert Map.has_key?(cache, {:pulls, 2}) and Map.has_key?(cache, {:main, 2})

      pace = snapshot.pace

      assert {pace.prs_total, pace.prs_merged, pace.prs_open, pace.prs_closed_unmerged} ==
               {105, 100, 3, 2}

      assert {pace.commits, pace.first_commit, pace.as_of} == {102, "2026-07-02", "2026-10-09"}

      assert pace.prs_by_day == [
               %{"date" => "2026-10-07", "created" => 5, "merged" => 0},
               %{"date" => "2026-10-09", "created" => 100, "merged" => 100}
             ]

      assert pace.commits_by_day == [
               %{"date" => "2026-07-02", "count" => 2},
               %{"date" => "2026-10-08", "count" => 100}
             ]

      # The feed itself still lists only the newest 15.
      assert length(snapshot.items) == 15
    end

    test "a list cut short (a later page fails, or too many pages) gives no pace" do
      full = for n <- 100..1//-1, do: pull(n, state: :merged)

      Req.Test.stub(GitHub, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case {Path.basename(conn.request_path), conn.query_params["page"]} do
          {"pulls", nil} -> Req.Test.json(conn, full)
          {"pulls", "2"} -> Plug.Conn.send_resp(conn, 502, "")
          {"commits", _} -> Req.Test.json(conn, commits(~w(c1)))
          {"runs", _} -> Req.Test.json(conn, runs([]))
        end
      end)

      Req.Test.stub(Versions, &Plug.Conn.send_resp(&1, 404, ""))

      {snapshot, cache} = Poller.poll(%{}, @now)
      assert snapshot.status == :ok
      assert length(snapshot.items) == 15
      assert snapshot.pace == nil
      refute Map.has_key?(cache, {:pulls, 2})

      config = Application.get_env(:ex_tales_forge, PrFeed, [])
      Application.put_env(:ex_tales_forge, PrFeed, Keyword.put(config, :max_pages, 1))
      on_exit(fn -> Application.put_env(:ex_tales_forge, PrFeed, config) end)

      assert {%{status: :ok, pace: nil}, _cache} = Poller.poll(%{}, @now)
    end

    test "main's commits failing gives no pace, the feed still works" do
      stub_github(%{
        pulls: json([pull(5, state: :open)]),
        ci: json(runs([])),
        main: &Plug.Conn.send_resp(&1, 500, "")
      })

      Req.Test.stub(Versions, &Plug.Conn.send_resp(&1, 404, ""))

      assert {%{status: :ok, items: [%{number: 5}], pace: nil}, _cache} = Poller.poll(%{}, @now)
    end

    test "sends the ETag back and reuses the parsed copy on 304" do
      test_pid = self()

      Req.Test.stub(GitHub, fn conn ->
        send(
          test_pid,
          {:if_none_match, conn.request_path, Plug.Conn.get_req_header(conn, "if-none-match")}
        )

        case Plug.Conn.get_req_header(conn, "if-none-match") do
          [_etag] -> Plug.Conn.send_resp(conn, 304, "")
          [] -> conn |> Plug.Conn.put_resp_header("etag", ~s(W/"v1")) |> Req.Test.json([pull(9)])
        end
      end)

      Req.Test.stub(Versions, &Plug.Conn.send_resp(&1, 404, ""))

      {first, cache} = Poller.poll(%{}, @now)
      assert [%{number: 9}] = first.items
      assert_received {:if_none_match, "/repos/whyse-ab/ex-tales-forge/pulls", []}
      assert {~s(W/"v1"), [_pr]} = cache[{:pulls, 1}]

      {second, _cache} = Poller.poll(cache, @now)
      assert second.items == first.items
      assert_received {:if_none_match, "/repos/whyse-ab/ex-tales-forge/pulls", [~s(W/"v1")]}
    end

    test "a 304 without a kept copy counts as unavailable" do
      Req.Test.stub(GitHub, &Plug.Conn.send_resp(&1, 304, ""))
      assert {%{status: :unavailable}, _} = Poller.poll(%{{:pulls, 1} => {"etag", nil}}, @now)
    end
  end

  describe "Versions" do
    test "this app's own GIT_SHA; the other app's from its /internal/version" do
      Application.put_env(:ex_tales_forge, :app_name, "tales-forge")
      System.put_env("GIT_SHA", "AbCdEf1234567")
      Application.put_env(:ex_tales_forge, :costs_peer, token: "peer-token")

      Req.Test.stub(Versions, fn conn ->
        assert conn.host == "tales-forge-playtest.fly.dev"
        Req.Test.json(conn, %{"app" => "playtest", "git_sha" => "702cf6f"})
      end)

      assert Versions.running() == %{production: "AbCdEf1234567", playtest: "702cf6f"}
    end

    test "no peer token, a down peer or a bad answer: nil" do
      Application.put_env(:ex_tales_forge, :app_name, "tales-forge")
      assert Versions.fetch(:playtest) == nil

      Application.put_env(:ex_tales_forge, :costs_peer, token: "peer-token")
      Req.Test.stub(Versions, &Req.Test.transport_error(&1, :timeout))
      assert Versions.fetch(:playtest) == nil

      Req.Test.stub(Versions, &Req.Test.json(&1, %{"git_sha" => "<script>"}))
      assert Versions.fetch(:playtest) == nil
    end
  end

  describe "publish/1" do
    test "stores the snapshot and broadcasts it" do
      :ok = PrFeed.subscribe()
      snapshot = snapshot([item(1)], today: 1)
      assert PrFeed.publish(snapshot) == :ok
      assert_receive {:pr_feed, ^snapshot}
      assert PrFeed.snapshot() == snapshot
    end
  end

  describe "extras: tests from CI and the decision log" do
    doctest TalesForge.PrFeed.Extras

    test "nothing stored: empty" do
      :ets.delete(TalesForge.PrFeed.Poller, :extras)
      assert TalesForge.PrFeed.Extras.current() == TalesForge.PrFeed.Extras.empty()
    end

    test "refresh keeps the last values within 10 minutes" do
      prev = %{tests: %{tests: 1}, decisions: nil, refreshed_at: ~U[2026-10-10 03:00:00Z]}
      assert TalesForge.PrFeed.Extras.refresh(prev, ~U[2026-10-10 03:05:00Z]) == prev
    end
  end
end
