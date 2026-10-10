defmodule TalesForgeWeb.TeamChatLiveTest do
  use TalesForgeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TalesForge.Chat

  setup %{conn: conn} do
    on_exit(fn -> Application.delete_env(:ex_tales_forge, :app_name) end)
    {:ok, conn: log_in_admin(conn, "fredrik@whyse.se", login: "fpahlen")}
  end

  # The panel is a portal (rendered at the end of <body>), which LiveViewTest
  # does not query: read the portal's <template> from the chat view's HTML,
  # and send the panel's events to the chat view directly.
  defp panel(chat) do
    html = render(chat)

    case Regex.run(~r{<template[^>]*>(.*)</template>}s, html) do
      [_, inner] -> LazyHTML.from_fragment(inner)
      _ -> LazyHTML.from_fragment("")
    end
  end

  defp panel_has?(chat, selector, text \\ nil) do
    chat
    |> panel()
    |> LazyHTML.query(selector)
    |> Enum.any?(&(text == nil or LazyHTML.text(&1) =~ text))
  end

  defp chat(view, prefix \\ "admin-online") do
    header = find_live_child(view, prefix)
    {header, find_live_child(header, prefix <> "-chat")}
  end

  test "the chat button opens the room; Close and Esc close it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin")
    {_header, chat} = chat(view)

    assert has_element?(
             chat,
             "#admin-online-chat-button[aria-expanded=false][aria-haspopup=dialog]"
           )

    chat |> element("#admin-online-chat-button") |> render_click()

    assert panel_has?(chat, "#admin-online-chat-panel[role=dialog][aria-modal=true]")
    assert panel_has?(chat, "#admin-online-chat-title", "Team chat")
    assert panel_has?(chat, "label[for=admin-online-chat-body]", "Message")
    assert panel_has?(chat, "#admin-online-chat-send[aria-label=Send]")
    assert panel_has?(chat, "#admin-online-chat-empty", "No messages yet")
    assert panel_has?(chat, "#admin-online-chat-body[rows='1'][phx-hook=MentionSuggest]")

    render_keydown(chat, "close", %{"key" => "Escape"})
    refute panel_has?(chat, "#admin-online-chat-panel")

    chat |> element("#admin-online-chat-button") |> render_click()
    render_click(chat, "close", %{})
    refute panel_has?(chat, "#admin-online-chat-panel")
  end

  test "sending a message shows it live with mentions highlighted", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/team")
    {_header, chat} = chat(view, "team-online")
    chat |> element("#team-online-chat-button") |> render_click()

    render_submit(chat, "send", %{"chat" => %{"body" => "Hi @Case and @max"}})
    html = render(chat)
    assert html =~ "Hi "
    assert panel_has?(chat, "#team-online-chat-messages span.font-semibold", "@Case")
    refute panel_has?(chat, "#team-online-chat-empty")
    assert_push_event(chat, "team_chat:sent", %{})
  end

  test "an empty message shows the reason", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin")
    {_header, chat} = chat(view)
    chat |> element("#admin-online-chat-button") |> render_click()
    render_submit(chat, "send", %{"chat" => %{"body" => "  "}})
    assert panel_has?(chat, "[role=alert]", "Write a message first.")
  end

  test "a mention of you shows an unread badge until you open the chat", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin")
    {_header, chat} = chat(view)
    refute has_element?(chat, "#admin-online-chat-unread")

    {:ok, _} = Chat.post("max@example.com", "@fredrik look at this")
    assert has_element?(chat, "#admin-online-chat-unread", "1")

    chat |> element("#admin-online-chat-button") |> render_click()
    refute has_element?(chat, "#admin-online-chat-unread")
    assert panel_has?(chat, "#admin-online-chat-messages li", "Mentions you")
  end

  test "Chat on a person in the online list opens the room with their @handle", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin")
    {header, chat} = chat(view)

    header |> element("#admin-online-toggle") |> render_click()
    header |> element("#admin-online-bot-gentry button", "Chat") |> render_click()

    assert panel_has?(chat, "#admin-online-chat-panel")
    assert render(chat) =~ "@gentry </textarea>"
  end

  test "on playtest there is no chat panel; Chat links to production", %{conn: conn} do
    Application.put_env(:ex_tales_forge, :app_name, "tales-forge-playtest")
    {:ok, view, _html} = live(conn, "/admin/play/sessions")
    header = find_live_child(view, "admin-online")
    refute find_live_child(header, "admin-online-chat")

    header |> element("#admin-online-toggle") |> render_click()

    assert has_element?(
             header,
             ~s(#admin-online-bot-case a[href="https://tales-forge.fly.dev/team"]),
             "Chat"
           )
  end

  test "messages are bubbles, newest at the bottom; your own sit on the right", %{conn: conn} do
    {:ok, _} = Chat.post("max@example.com", "first from Max")
    {:ok, _} = Chat.post("bot:case", "then Case")
    {:ok, view, _html} = live(conn, "/admin")
    {_header, chat} = chat(view)
    chat |> element("#admin-online-chat-button") |> render_click()
    render_submit(chat, "send", %{"chat" => %{"body" => "and me"}})

    texts =
      chat
      |> panel()
      |> LazyHTML.query("#admin-online-chat-messages > li")
      |> Enum.map(&LazyHTML.text/1)

    assert [a, b, c] = texts
    assert a =~ "first from Max" and b =~ "then Case" and c =~ "and me"
    assert panel_has?(chat, "#admin-online-chat-messages > li.flex-row-reverse", "and me")

    assert panel_has?(
             chat,
             "#admin-online-chat-messages > li img[src='/images/team/case-avatar-96.jpg']"
           )
  end

  test "message text is escaped and keeps its own line breaks only", %{conn: conn} do
    {:ok, _} = Chat.post("max@example.com", "<b>hi</b> @fredrik\nnext")
    {:ok, view, _html} = live(conn, "/admin")
    {_header, chat} = chat(view)
    chat |> element("#admin-online-chat-button") |> render_click()
    html = render(chat)

    assert html =~
             "&lt;b&gt;hi&lt;/b&gt; <span class=\"font-semibold text-[var(--paper-accent)]\">@fredrik</span>\nnext</p>"
  end

  # LiveViewTest cannot upload into a portal, so the upload itself is tested on
  # the card (team_idea_board_test.exs) and in TalesForge.ImagesTest.
  test "the composer takes images: file button, drop target, paste hook, capture button",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/team")
    {_header, chat} = chat(view, "team-online")
    chat |> element("#team-online-chat-button") |> render_click()

    assert panel_has?(chat, "#team-online-chat-form[phx-hook=ImageInput][phx-drop-target]")
    assert panel_has?(chat, "#team-online-chat-images label", "Add image")

    assert panel_has?(
             chat,
             ~s(input[type=file][name=chat_images][accept=".png,.jpg,.jpeg,.webp"])
           )

    assert panel_has?(chat, "#team-online-chat-images-capture[hidden]", "Capture screen")
  end

  test "a message with an image shows a thumbnail that opens the full image", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/team")
    {_header, chat} = chat(view, "team-online")
    chat |> element("#team-online-chat-button") |> render_click()

    {:ok, m} = Chat.post("max@example.com", "", images: [TalesForge.ImageFixtures.png()])
    [image] = m.images

    assert panel_has?(
             chat,
             ~s(#team-online-chat-msg-#{m.id} a[href="/team/images/#{image.id}"][target=_blank] img)
           )
  end
end
