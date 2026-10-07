defmodule TalesForgeWeb.CreateCharacterLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias TalesForge.Jido
  alias TalesForge.Repo
  alias TalesForge.Schemas.{AICall, Character, GameSession}

  setup %{conn: conn} do
    on_exit(fn ->
      for {id, _pid} <- Jido.list_agents(), do: Jido.stop_agent(id)
    end)

    {:ok, conn: log_in_admin(conn)}
  end

  test "the screen needs a signed-in team member" do
    for conn <- [build_conn(), log_in_non_member(build_conn())] do
      assert redirected_to(get(conn, ~p"/new/tin_valley")) =~ "/admin/login"
    end
  end

  defp points(view), do: view |> element("#points-left") |> render() |> text_int()

  defp text_int(html),
    do: ~r/<[^>]+>/ |> Regex.replace(html, "") |> String.trim() |> String.to_integer()

  defp total(view, stat) do
    view
    |> element("#total-#{stat}")
    |> render()
    |> text_int()
  end

  defp to_stats(view) do
    view |> element("#next-stats") |> render_click()
    view
  end

  describe "the happy path" do
    test "race, class, stats, race bonus, name, then a game with that character", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/new/tin_valley")

      assert html =~ "Create your character"
      assert html =~ "Your first character is free"
      assert html =~ "Coming later: Background · Standing · Origin · Occupation"

      view |> element("#race-elf") |> render_click()
      view |> element("#class-ranger") |> render_click()
      assert view |> element("#race-elf[aria-checked=true]") |> has_element?()
      assert view |> element("#class-ranger[aria-checked=true]") |> has_element?()

      to_stats(view)
      # ranger: DEX 14, WIS 13; the elf bonus defaults to WIS (the higher one)
      assert points(view) == 0
      assert total(view, "DEX") == 16
      assert total(view, "WIS") == 14
      assert total(view, "CON") == 11

      view |> element("#pick-INT") |> render_click()
      assert total(view, "INT") == 13
      assert total(view, "WIS") == 13

      view |> element("#dec-CHA") |> render_click()
      assert points(view) == 1
      view |> element("#inc-CON") |> render_click()
      assert points(view) == 0
      assert total(view, "CON") == 12

      view |> element("#next-name") |> render_click()
      assert has_element?(view, "#name-step")
      view |> element("#name-form") |> render_change(%{"name" => "Sela Vorn"})
      assert view |> element("#summary") |> render() =~ "Sela Vorn"

      view |> element("#name-form") |> render_submit(%{"name" => "Sela Vorn"})
      {path, _flash} = assert_redirect(view)
      "/play/" <> session_id = path

      session = Repo.get!(GameSession, session_id)
      pc = session.world_state["character"]
      assert session.name == "Tin Valley · Sela Vorn"
      assert pc["id"] == "pc_sela_vorn"
      assert pc["name"] == "Sela Vorn"
      assert pc["race"] == "elf"
      assert pc["class"] == "ranger"

      assert pc["stats"] == %{
               "STR" => 12,
               "DEX" => 16,
               "CON" => 12,
               "INT" => 13,
               "WIS" => 13,
               "CHA" => 11
             }

      row = Repo.get_by!(Character, game_session_id: session.id, controller: "player")
      assert row.slug == "pc_sela_vorn"
      assert row.name == "Sela Vorn"
      assert row.race == "elf"
      assert row.stats.dex == 16
      assert row.skills == %{"ranged_combat" => 3, "tracking" => 2}
      assert row.origin["source"] == "created"
      refute Repo.get_by(Character, game_session_id: session.id, slug: "elara_voss")

      # creation made no AI calls (none without a session): the first character is free
      assert Repo.aggregate(from(c in AICall, where: is_nil(c.game_session_id)), :count) == 0
    end

    test "Crossroads Hamlet works the same way", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/new/crossroads_ledger")
      view |> element("#class-warrior") |> render_click()
      to_stats(view)
      view |> element("#next-name") |> render_click()
      view |> element("#name-form") |> render_submit(%{"name" => "Brann"})
      {"/play/" <> id, _} = assert_redirect(view)

      assert %{"name" => "Brann", "location_id" => "weary_pilgrim"} =
               Repo.get!(GameSession, id).world_state["character"]
    end
  end

  describe "the point buy" do
    test "points left update live and the buttons stop at the limits", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/new/tin_valley")
      to_stats(view)

      # no class: 12s across, 72 of 75
      assert points(view) == 3
      for _ <- 1..3, do: view |> element("#inc-STR") |> render_click()
      assert points(view) == 0
      assert view |> element("#inc-DEX[disabled]") |> has_element?()

      for _ <- 1..9, do: view |> element("#dec-CHA") |> render_click()
      assert view |> element("#dec-CHA[disabled]") |> has_element?()
      assert points(view) == 9

      for _ <- 1..3, do: view |> element("#inc-STR") |> render_click()
      assert view |> element("#inc-STR[disabled]") |> has_element?()
      assert total(view, "STR") == 19
    end

    test "a race bonus past 18 is shown inline and blocks the next step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/new/tin_valley")
      view |> element("#race-elf") |> render_click()
      to_stats(view)

      for _ <- 1..3, do: view |> element("#dec-CHA") |> render_click()
      for _ <- 1..5, do: view |> element("#inc-DEX") |> render_click()

      assert view |> element("#stats-errors") |> render() =~
               "DEX would be 19 after the elf modifier (+2); it must be 3–18"

      assert view |> element("#next-name[disabled]") |> has_element?()
      assert view |> element("#step-name[disabled]") |> has_element?()

      view |> element("#dec-DEX") |> render_click()
      refute has_element?(view, "#stats-errors")
      view |> element("#next-name") |> render_click()
      assert has_element?(view, "#name-step")
    end

    test "a stat can't go below 3 even if the event is forced", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/new/tin_valley")
      to_stats(view)
      html = render_click(view, "stat", %{"stat" => "STR", "delta" => "-10"})
      assert html =~ "STR must be a whole number from 3 to 18"
      assert total(view, "STR") == 13
    end
  end

  describe "racial bonuses" do
    test "Human picks any two stats; a new pick replaces the oldest", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/new/tin_valley")
      to_stats(view)

      assert view |> element("#race-bonus") |> render() =~ "+1 to any 2 stats"
      assert view |> element("#pick-STR[aria-pressed=true]") |> has_element?()
      assert view |> element("#pick-DEX[aria-pressed=true]") |> has_element?()

      view |> element("#pick-CHA") |> render_click()
      assert view |> element("#pick-STR[aria-pressed=false]") |> has_element?()
      assert total(view, "STR") == 12
      assert total(view, "CHA") == 13
      assert total(view, "DEX") == 13
    end

    test "a race without a choice shows its fixed modifiers and no picker", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/new/tin_valley")
      view |> element("#race-dwarf") |> render_click()
      to_stats(view)

      refute has_element?(view, "#race-bonus")
      assert view |> element("#stat-CON") |> render() =~ "+2"
      assert total(view, "CON") == 14
      assert total(view, "CHA") == 11
    end
  end

  describe "the name" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/new/tin_valley")
      to_stats(view)
      view |> element("#next-name") |> render_click()
      %{view: view}
    end

    test "an empty name is refused inline and starts nothing", %{view: view} do
      count = Repo.aggregate(GameSession, :count)
      html = view |> element("#name-form") |> render_submit(%{"name" => "   "})
      assert html =~ "Type a name"
      assert has_element?(view, "#character-name[aria-invalid=true]")
      assert Repo.aggregate(GameSession, :count) == count
    end

    test "a name over 40 characters is refused inline", %{view: view} do
      html =
        view |> element("#name-form") |> render_change(%{"name" => String.duplicate("a", 41)})

      assert html =~ "A name has at most 40 characters"

      html = view |> element("#name-form") |> render_change(%{"name" => "Wren"})
      refute html =~ "at most 40 characters"
    end
  end

  test "an unknown adventure goes back home", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/", flash: %{"error" => "Unknown adventure."}}}} =
             live(conn, ~p"/new/atlantis")
  end

  test "the home page offers creation and the Elara quick start", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert html =~ "Create a character"
    assert html =~ "Quick start as Elara"

    view |> element("#create-tin_valley") |> render_click()
    assert_redirect(view, ~p"/new/tin_valley")

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#quick-tin_valley") |> render_click()
    {"/play/" <> id, _} = assert_redirect(view)
    assert Repo.get!(GameSession, id).world_state["character"]["id"] == "elara_voss"
  end
end
