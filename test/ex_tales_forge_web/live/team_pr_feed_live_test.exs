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
