defmodule TalesForgeWeb.OnlineHeaderLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.Online.Peer

  setup %{conn: conn} do
    # Restore the configured value, so later tests see the real flag.
    previous = Application.get_env(:ex_tales_forge, :team_chat_placeholder)

    on_exit(fn ->
      Peer.put([], ~U[2000-01-01 00:00:00Z])
      Application.put_env(:ex_tales_forge, :team_chat_placeholder, previous)
    end)

    {:ok, conn: log_in_admin(conn, "fredrik@example.com")}
  end

  for {path, prefix} <- [
        {"/admin", "admin-online"},
        {"/team", "team-online"},
        {"/team/presentation", "team-online"}
      ] do
    @path path
    @prefix prefix

    test "#{path}: the header shows the counter, closed", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      header = find_live_child(view, @prefix)
      assert header

      html = render(header)
      assert html =~ "Founders: 1"
      assert html =~ ~r"Bots: \d"

      assert has_element?(
               header,
               "##{@prefix}-toggle[aria-expanded=false][aria-controls=#{@prefix}-list]"
             )

      refute has_element?(header, "##{@prefix}-list")
    end
  end

  test "the button opens the list; Esc and a click outside close it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin")
    header = find_live_child(view, "admin-online")

    header |> element("#admin-online-toggle") |> render_click()
    assert has_element?(header, "#admin-online-toggle[aria-expanded=true]")
    assert has_element?(header, "#admin-online-list[role=region][tabindex='-1']")

    assert has_element?(
             header,
             "#admin-online-founder-local-fredrik-example-com",
             "Admin on local"
           )

    for bot <- ~w(case bobby gentry), do: assert(has_element?(header, "#admin-online-bot-#{bot}"))

    render_keydown(element(header, "#admin-online-presence"), %{"key" => "Escape"})
    refute has_element?(header, "#admin-online-list")
    assert has_element?(header, "#admin-online-toggle[aria-expanded=false]")
  end

  test "founders on playtest and active bots are counted", %{conn: conn} do
    now = DateTime.utc_now()

    Peer.put(
      [%{email: "max@example.com", page: "Playtest runs", app: "playtest", since: now}],
      now
    )

    TalesForge.Online.bot_seen(:case)

    {:ok, view, _html} = live(conn, "/admin")
    header = find_live_child(view, "admin-online")
    html = render(header)
    assert html =~ "Founders: 2"
    assert html =~ ~r"Bots: [1-3]"

    header |> element("#admin-online-toggle") |> render_click()

    assert has_element?(
             header,
             "#admin-online-founder-playtest-max-example-com",
             "Playtest runs on playtest"
           )

    assert has_element?(header, "#admin-online-bot-case", "Read the board")
  end

  test "Chat is a disabled placeholder behind the config flag", %{conn: conn} do
    Application.put_env(:ex_tales_forge, :team_chat_placeholder, true)
    {:ok, view, _html} = live(conn, "/admin")
    header = find_live_child(view, "admin-online")
    header |> element("#admin-online-toggle") |> render_click()

    assert has_element?(
             header,
             "#admin-online-founders button[disabled][title='Coming with team chat']",
             "Chat"
           )

    Application.put_env(:ex_tales_forge, :team_chat_placeholder, false)
    {:ok, view, _html} = live(conn, "/admin")
    header = find_live_child(view, "admin-online")
    header |> element("#admin-online-toggle") |> render_click()
    refute render(header) =~ "Coming with team chat"
  end
end
