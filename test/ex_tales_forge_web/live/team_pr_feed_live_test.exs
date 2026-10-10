defmodule TalesForgeWeb.TeamPrFeedLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TalesForge.PrFeedFixtures

  alias TalesForge.PrFeed
  alias TalesForge.PrFeed.Poller
  alias TalesForgeWeb.TeamPrFeedLive

  doctest TalesForgeWeb.TeamPrFeed

  setup %{conn: conn} do
    on_exit(fn ->
      :ets.delete(Poller, :snapshot)
      Application.put_env(:ex_tales_forge, :pr_feed_token, nil)
    end)

    {:ok, conn: log_in_admin(conn)}
  end

  defp feed(conn) do
    {:ok, view, _html} = live(conn, ~p"/team")
    {view, find_live_child(view, "team-pr-feed")}
  end

  test "signed out, the feed LiveView can't be mounted on its own" do
    assert {:error, {:redirect, %{to: "/admin/login" <> _}}} =
             live_isolated(build_conn(), TeamPrFeedLive)
  end

  test "no token: 'Live feed unavailable', and the rest of the page renders", %{conn: conn} do
    {view, child} = feed(conn)
    assert has_element?(view, "#team-nav a[href='#live']", "Doing now")
    assert has_element?(view, "#live-title", "What we're doing now")
    assert has_element?(child, "#pr-feed-unavailable", "Live feed unavailable")
    assert render(child) =~ "no GitHub token"
    assert has_element?(view, "#idea-board")
    assert has_element?(view, "#presentation-cta")
  end

  test "token set but no poll yet: loading", %{conn: conn} do
    Application.put_env(:ex_tales_forge, :pr_feed_token, "feed-token")
    {_view, child} = feed(conn)
    assert has_element?(child, "#pr-feed[data-status='loading']")
  end

  test "GitHub down: 'Live feed unavailable' with the reason", %{conn: conn} do
    PrFeed.publish(PrFeed.empty(:unavailable, DateTime.utc_now()))
    {view, child} = feed(conn)
    assert has_element?(child, "#pr-feed-unavailable", "Live feed unavailable")
    assert render(child) =~ "GitHub didn&#39;t answer"
    assert has_element?(view, "#idea-board")
  end

  test "renders the stored snapshot: counters, states, CI and deployments", %{conn: conn} do
    PrFeed.publish(
      snapshot(
        [
          item(12, state: :open, ci: :failed, title: "Fix the inn door"),
          item(11, state: :merged, deployed: %{playtest: :deployed, production: :pending}),
          item(10, state: :merged, deployed: %{playtest: :deployed, production: :deployed}),
          item(9, state: :closed)
        ],
        today: 2,
        week: 7
      )
    )

    {_view, child} = feed(conn)

    assert has_element?(child, "#pr-feed-today", "2")
    assert has_element?(child, "#pr-feed-week", "7")
    assert has_element?(child, "#pr-feed-12 a[href$='/pull/12']", "Fix the inn door")
    assert has_element?(child, "#pr-feed-12 .pr-feed-pill", "Open")
    assert has_element?(child, "#pr-feed-12 [data-kind='ci-failed']", "CI failing")
    assert has_element?(child, "#pr-feed-11 [data-kind='on-playtest']", "on playtest")
    assert has_element?(child, "#pr-feed-11 [data-kind='waiting']", "not on prod yet")
    assert has_element?(child, "#pr-feed-10 [data-kind='on-prod']", "on prod")
    assert has_element?(child, "#pr-feed-9 .pr-feed-pill", "Closed")
    refute has_element?(child, "#pr-feed-9 .pr-feed-chip")
    assert render(child) =~ "opened 5 minutes ago"
    refute has_element?(child, "[data-fresh]")
  end

  test "a PubSub update re-renders live and marks only new or changed PRs fresh", %{conn: conn} do
    PrFeed.publish(snapshot([item(2, state: :open, ci: :running), item(1, state: :merged)]))
    {_view, child} = feed(conn)
    refute has_element?(child, "#pr-feed-3")

    PrFeed.publish(
      snapshot(
        [
          item(3, state: :open, title: "Brand new"),
          item(2, state: :merged, deployed: %{playtest: :pending, production: :pending}),
          item(1, state: :merged)
        ],
        today: 2
      )
    )

    assert has_element?(child, "#pr-feed-3[data-fresh]", "Brand new")
    assert has_element?(child, "#pr-feed-2[data-fresh] .pr-feed-pill", "Merged")
    assert has_element?(child, "#pr-feed-2 [data-kind='waiting']", "not on playtest yet")
    refute has_element?(child, "#pr-feed-1[data-fresh]")
    assert has_element?(child, "#pr-feed-today", "2")

    PrFeed.publish(PrFeed.empty(:unavailable, DateTime.utc_now()))
    assert has_element?(child, "#pr-feed-unavailable")
  end

  test "an empty feed says so", %{conn: conn} do
    PrFeed.publish(snapshot([]))
    {_view, child} = feed(conn)
    assert has_element?(child, "#pr-feed-empty", "No pull requests yet.")
  end

  test "fresh/2 marks nothing on the first data" do
    snap = snapshot([item(1)])
    assert TeamPrFeedLive.fresh(snap, MapSet.new()) == MapSet.new()
    assert TeamPrFeedLive.fresh(snap, MapSet.new([{1, :open}])) == MapSet.new()
    assert TeamPrFeedLive.fresh(snap, MapSet.new([{2, :open}])) == MapSet.new([1])
  end
end

defmodule TalesForgeWeb.TeamPrFeedListTest do
  @moduledoc "The /team feed list: newest 5, in-flight pulse, live-on-prod marker, times (2026-10-10)."
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TalesForge.PrFeedFixtures

  alias TalesForge.PrFeed
  alias TalesForgeWeb.TeamPrFeed

  doctest TalesForgeWeb.TeamPrFeed, only: [in_flight?: 1, stamp: 1, span_text: 2, duration: 1]

  @prod %{playtest: :deployed, production: :deployed}
  @waiting %{playtest: :deployed, production: :pending}

  defp child(conn) do
    {:ok, view, _} = live(log_in_admin(conn), "/team")
    find_live_child(view, "team-pr-feed") || view
  end

  defp flight(view, n), do: has_element?(view, "#pr-feed-#{n}[data-in-flight]")

  test "only the newest 5; every in-flight one pulses; shipped ones get the done marker", %{
    conn: conn
  } do
    PrFeed.publish(
      snapshot([
        item(7, state: :open),
        item(6, state: :merged, deployed: @waiting, merged_at: ~U[2026-10-10 03:00:00Z]),
        item(5, state: :merged, deployed: @prod, merged_at: ~U[2026-10-10 02:00:00Z]),
        item(4, state: :closed),
        item(3,
          state: :merged,
          deployed: %{playtest: :unknown, production: :unknown},
          merged_at: ~U[2026-10-09 09:00:00Z]
        ),
        item(2, state: :open),
        item(1, state: :open)
      ])
    )

    view = child(conn)
    for n <- 7..3//-1, do: assert(has_element?(view, "#pr-feed-#{n}"))
    refute has_element?(view, "#pr-feed-2")
    refute has_element?(view, "#pr-feed-1")

    assert flight(view, 7)
    assert flight(view, 6)
    refute flight(view, 5)
    refute flight(view, 4)
    refute flight(view, 3)
    assert has_element?(view, "#pr-feed-5 [data-role=live-on-prod]", "live on prod")
    refute has_element?(view, "#pr-feed-6 [data-role=live-on-prod]")
  end

  test "nothing in flight: nothing pulses", %{conn: conn} do
    PrFeed.publish(
      snapshot([
        item(2, state: :merged, deployed: @prod, merged_at: ~U[2026-10-09 09:00:00Z]),
        item(1, state: :closed)
      ])
    )

    view = child(conn)
    refute has_element?(view, "[data-in-flight]")
  end

  test "the pulse only runs with full motion and never under reduced motion", %{conn: conn} do
    PrFeed.publish(snapshot([item(1, state: :open)]))
    html = conn |> child() |> render()

    assert html =~
             ~s(.team-page[data-motion="full"] .pr-feed-item[data-in-flight] { animation: pr-feed-alive)

    assert html =~
             "@media (prefers-reduced-motion: reduce) { .pr-feed-item[data-in-flight] { animation: none !important; } }"
  end

  test "times: merged shows the merge time and how long it took; open shows how long so far", %{
    conn: conn
  } do
    PrFeed.publish(
      snapshot([
        item(2, state: :open, opened_at: DateTime.add(DateTime.utc_now(), -2 * 3600 - 300)),
        item(1,
          state: :merged,
          deployed: @prod,
          opened_at: ~U[2026-10-08 08:00:00Z],
          merged_at: ~U[2026-10-09 09:30:00Z]
        )
      ])
    )

    view = child(conn)
    assert has_element?(view, "#pr-feed-1 [data-role=pr-stamp]", "Merged 9 Oct 11:30 CEST")
    assert has_element?(view, "#pr-feed-1 [data-role=pr-span]", "took 1 d 1 h from open to merge")
    assert has_element?(view, "#pr-feed-2 [data-role=pr-stamp]", "Opened ")
    assert has_element?(view, "#pr-feed-2 [data-role=pr-span]", "open for 2 h 5 min")
  end

  describe "formatting across DST (Europe/Stockholm, 25 Oct 2026 03:00 CEST -> 02:00 CET)" do
    test "stamps switch CEST to CET" do
      assert TeamPrFeed.stamp(%{state: :open, opened_at: ~U[2026-10-25 00:30:00Z]}) ==
               "Opened 25 Oct 02:30 CEST"

      assert TeamPrFeed.stamp(%{state: :open, opened_at: ~U[2026-10-25 01:30:00Z]}) ==
               "Opened 25 Oct 02:30 CET"

      assert TeamPrFeed.stamp(%{
               state: :merged,
               opened_at: nil,
               merged_at: ~U[2026-03-29 01:30:00Z]
             }) ==
               "Merged 29 Mar 03:30 CEST"
    end

    test "spans count real time, not wall clock" do
      # 01:30 CEST to 02:30 CET on the clock is 2 real hours.
      pr = %{
        state: :merged,
        opened_at: ~U[2026-10-24 23:30:00Z],
        merged_at: ~U[2026-10-25 01:30:00Z]
      }

      assert TeamPrFeed.span_text(pr, ~U[2026-10-26 00:00:00Z]) == "took 2 h from open to merge"
      # Spring forward: 01:30 CET to 03:30 CEST on the clock is 1 real hour.
      open = %{state: :open, opened_at: ~U[2026-03-29 00:30:00Z], merged_at: nil}
      assert TeamPrFeed.span_text(open, ~U[2026-03-29 01:30:00Z]) == "open for 1 h"
    end

    test "no times: no line" do
      assert TeamPrFeed.stamp(%{state: :open, opened_at: nil}) == nil
      assert TeamPrFeed.span_text(%{state: :closed, opened_at: nil}, DateTime.utc_now()) == nil
    end
  end
end
