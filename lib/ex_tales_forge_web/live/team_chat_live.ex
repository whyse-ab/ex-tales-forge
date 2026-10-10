defmodule TalesForgeWeb.TeamChatLive do
  @moduledoc """
  The team chat panel (`TalesForge.Chat`), opened from the header: the
  "Chat" button next to the who-is-online counter, or the "Chat" button on a
  person in that list (the message box then starts with their `@handle`).
  Nested in `TalesForgeWeb.OnlineHeaderLive`, which loads it through config
  `:team_chat_live` on production and locally.

  - The chat button shows the number of unread mentions of you (your handle
    comes from your GitHub login, `TalesForge.Board.Mentions`).
  - Accessible: the panel is a `role="dialog"` with a title; focus moves to
    the message box when it opens; Esc or "Close" closes it and moves focus
    back to the chat button. New messages are announced (`aria-live`).
  - The panel is rendered at the end of `<body>` (`portal`), so the header's
    blur does not trap it: an opaque, full-height drawer above the page.
    Messages are bubbles (avatar, name, time), newest at the bottom, and the
    list scrolls down by itself (`TeamChat` hook in `assets/js/team_hooks.js`).
  - Composer pinned to the bottom: a one-line box that grows, Enter sends,
    Shift+Enter adds a new line; typing @ suggests names (`MentionSuggest`).
  - Images (`TalesForge.Images`, `TalesForgeWeb.TeamImages`): paste, drop or
    pick PNG, JPEG or WebP files, or "Capture screen" (one still of a tab,
    window or screen; desktop only). The chosen images show as previews above
    the message box; the text is the note and can be empty. Sent images show
    as thumbnails that open the full image.
  - Phone: the panel fills the screen; from `sm` up it is a side panel.
  """

  use TalesForgeWeb, :live_view

  alias Phoenix.LiveView.JS
  alias TalesForge.Chat
  alias TalesForge.Chat.Message
  alias TalesForge.TeamOnline
  alias TalesForgeWeb.TeamImages
  alias TalesForgeWeb.TimeAgo

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t(), keyword()}
  def mount(_params, session, socket) do
    login = socket.assigns[:admin_github_login]

    if connected?(socket) do
      Chat.subscribe()
      if socket.parent_pid, do: send(socket.parent_pid, {:team_chat_pid, self()})
    end

    {:ok,
     socket
     |> assign(:id_prefix, session["id_prefix"] || "chat")
     |> assign(:login, login)
     |> assign(:email, socket.assigns[:admin_email])
     |> assign(:me, Chat.handle_for(login))
     |> assign(:open, false)
     |> assign(:draft, "")
     |> assign(:messages, [])
     |> assign(:unread, Chat.unread(login))
     |> assign(:form, to_form(%{"body" => ""}, as: :chat))
     |> TeamImages.allow(:chat_images), layout: false}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("open", _params, socket), do: {:noreply, open(socket, nil)}
  def handle_event("close", _params, socket), do: {:noreply, assign(socket, :open, false)}

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_image", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :chat_images, ref)}

  def handle_event("send", params, socket) do
    body = get_in(params, ["chat", "body"]) || ""
    images = TeamImages.read_all(socket, :chat_images)

    case Chat.post(socket.assigns.admin_email, body, login: socket.assigns.login, images: images) do
      {:ok, _message} ->
        {:noreply,
         socket
         |> assign(:form, to_form(%{"body" => ""}, as: :chat))
         |> push_event("team_chat:sent", %{})}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :chat))}
    end
  end

  @impl true
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info({:open_chat, to}, socket), do: {:noreply, open(socket, to)}

  def handle_info({:team_chat, %Message{} = m}, socket) do
    if socket.assigns.open do
      Chat.mark_read(socket.assigns.login)
      {:noreply, assign(socket, :messages, socket.assigns.messages ++ [m])}
    else
      {:noreply, assign(socket, :unread, Chat.unread(socket.assigns.login))}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp open(socket, to) do
    Chat.mark_read(socket.assigns.login)
    body = if to, do: "@#{mention(to)} ", else: ""

    socket
    |> assign(open: true, unread: 0, messages: Chat.recent())
    |> assign(:form, to_form(%{"body" => body}, as: :chat))
  end

  # The handle to start a message with: "bot:<name>", a founder's @handle
  # (from their GitHub login) or, without one, their email.
  defp mention("bot:" <> bot), do: bot

  defp mention(to) do
    if String.contains?(to, "@"),
      do: Chat.handle_for_email(to) || to |> String.split("@") |> hd(),
      else: to
  end

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div id={"#{@id_prefix}-root"} class="contents">
      <button
        id={"#{@id_prefix}-button"}
        type="button"
        phx-click="open"
        aria-haspopup="dialog"
        aria-expanded={to_string(@open)}
        aria-controls={"#{@id_prefix}-panel"}
        class="relative inline-flex min-h-9 items-center gap-1 rounded-full border border-[var(--paper-rule)] px-2.5 py-1 text-xs font-semibold text-[var(--paper-ink)] hover:bg-[var(--paper-bg)] focus-visible:outline-2 focus-visible:outline-[var(--paper-accent)] sm:text-sm"
      >
        <.icon name="hero-chat-bubble-left-right" class="size-4" />
        <span>Chat</span>
        <span
          :if={@unread > 0}
          id={"#{@id_prefix}-unread"}
          class="ml-0.5 rounded-full bg-[var(--paper-accent)] px-1.5 text-[0.7rem] leading-5 text-white"
        >
          {@unread}<span class="sr-only"> new mentions of you</span>
        </span>
      </button>

      <.portal :if={@open} id={"#{@id_prefix}-portal"} target="body">
        <div
          id={"#{@id_prefix}-backdrop"}
          class="fixed inset-0 z-[90] hidden bg-black/30 sm:block"
          phx-click={
            JS.push("close", target: "##{@id_prefix}-root") |> JS.focus(to: "##{@id_prefix}-button")
          }
          aria-hidden="true"
        >
        </div>
        <div
          id={"#{@id_prefix}-panel"}
          role="dialog"
          aria-modal="true"
          aria-labelledby={"#{@id_prefix}-title"}
          phx-hook="TeamChat"
          phx-window-keydown={
            JS.push("close", target: "##{@id_prefix}-root") |> JS.focus(to: "##{@id_prefix}-button")
          }
          phx-key="Escape"
          class="team-chat-panel fixed inset-y-0 right-0 z-[100] flex h-dvh w-full flex-col bg-[var(--paper-panel)] text-left text-[var(--paper-ink)] shadow-2xl sm:w-[26rem] sm:border-l sm:border-[var(--paper-rule)]"
          style="background-color: var(--paper-panel, #fbf6ec);"
        >
          <header class="flex shrink-0 items-center justify-between gap-2 border-b border-[var(--paper-rule)] px-4 py-2">
            <h2 id={"#{@id_prefix}-title"} class="font-serif text-lg font-semibold">Team chat</h2>
            <button
              id={"#{@id_prefix}-close"}
              type="button"
              phx-click={
                JS.push("close", target: "##{@id_prefix}-root")
                |> JS.focus(to: "##{@id_prefix}-button")
              }
              aria-label="Close the chat"
              class="inline-flex size-11 items-center justify-center rounded-full hover:bg-[var(--paper-bg)]"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </button>
          </header>

          <ol
            id={"#{@id_prefix}-messages"}
            data-chat-scroll
            aria-live="polite"
            aria-label="Messages"
            class="min-h-0 flex-1 space-y-3 overflow-y-auto overscroll-contain px-3 py-4"
          >
            <li
              :if={@messages == []}
              id={"#{@id_prefix}-empty"}
              class="grid h-full place-items-center text-sm text-[var(--paper-muted)]"
            >
              No messages yet
            </li>
            <li
              :for={m <- @messages}
              id={"#{@id_prefix}-msg-#{m.id}"}
              class={["flex items-end gap-2", mine?(m, @email) && "flex-row-reverse"]}
            >
              <.avatar author={m.author} />
              <div class={[
                "max-w-[80%] rounded-2xl px-3 py-2 text-sm leading-relaxed shadow-sm",
                if(mine?(m, @email),
                  do: "rounded-br-sm bg-[#f3dcae] text-[#2b1d0e]",
                  else: "rounded-bl-sm border border-[var(--paper-rule)] bg-[var(--paper-bg)]"
                ),
                @me && @me in m.mentions && "ring-2 ring-[var(--paper-accent)]"
              ]}>
                <p class="flex flex-wrap items-baseline gap-x-2 text-xs">
                  <span class="font-semibold">{author(m.author)}</span>
                  <time
                    datetime={DateTime.to_iso8601(m.inserted_at)}
                    class="text-[var(--paper-muted)]"
                  >
                    {TimeAgo.stockholm(m.inserted_at, "%d %b %H:%M")}
                  </time>
                  <span
                    :if={@me && @me in m.mentions}
                    class="font-semibold text-[var(--paper-accent)]"
                  >
                    Mentions you
                  </span>
                </p>
                <p :if={m.body != ""} class="whitespace-pre-wrap break-words">{body(m.body)}</p>
                <TeamImages.thumbnails
                  images={images(m)}
                  id={"#{@id_prefix}-msg-#{m.id}-images"}
                  class="mt-1"
                />
              </div>
            </li>
          </ol>

          <.form
            for={@form}
            id={"#{@id_prefix}-form"}
            phx-submit={JS.push("send", target: "##{@id_prefix}-root")}
            phx-change="validate"
            phx-target={"##{@id_prefix}-root"}
            phx-drop-target={@uploads.chat_images.ref}
            phx-hook="ImageInput"
            class="shrink-0 border-t border-[var(--paper-rule)] bg-[var(--paper-panel)] px-3 pb-[max(0.75rem,env(safe-area-inset-bottom))] pt-2"
          >
            <p
              :for={msg <- Enum.map(@form[:body].errors, &elem(&1, 0))}
              class="pb-1 text-sm text-red-700"
              role="alert"
            >
              {msg}
            </p>
            <TeamImages.picker
              upload={@uploads.chat_images}
              id={"#{@id_prefix}-images"}
              target={"##{@id_prefix}-root"}
            />
            <div class="relative mt-2 flex items-end gap-2">
              <label for={"#{@id_prefix}-body"} class="sr-only">Message</label>
              <textarea
                id={"#{@id_prefix}-body"}
                name="chat[body]"
                rows="1"
                maxlength={Message.max_length()}
                placeholder="Message or image note (@ to mention)"
                phx-mounted={JS.focus()}
                phx-hook="MentionSuggest"
                data-handles={Jason.encode!(Chat.suggestions())}
                data-chat-input
                aria-autocomplete="list"
                aria-controls={"#{@id_prefix}-mention-list"}
                aria-describedby={"#{@id_prefix}-hint"}
                class="max-h-40 min-h-11 flex-1 resize-none rounded-2xl border border-[var(--paper-rule)] bg-[var(--paper-bg)] px-3 py-2.5 text-base leading-snug"
              >{Phoenix.HTML.Form.normalize_value("textarea", @form[:body].value)}</textarea>
              <ul
                id={"#{@id_prefix}-mention-list"}
                role="listbox"
                aria-label="Names to mention"
                phx-update="ignore"
                hidden
                class="absolute bottom-full left-0 z-10 mb-1 max-h-48 overflow-y-auto rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] text-sm shadow"
              >
              </ul>
              <button
                id={"#{@id_prefix}-send"}
                type="submit"
                aria-label="Send"
                class="team-cta inline-flex size-11 shrink-0 items-center justify-center rounded-full"
              >
                <.icon name="hero-paper-airplane" class="size-5" />
              </button>
            </div>
            <p id={"#{@id_prefix}-hint"} class="sr-only">
              Enter sends, Shift and Enter adds a new line. Write @ to mention a founder or a bot. Paste or drop an image to add it.
            </p>
          </.form>
        </div>
      </.portal>
    </div>
    """
  end

  # The message text with mentions highlighted, built here and not in the
  # template, so no template whitespace shows inside `whitespace-pre-wrap`.
  # Each part is escaped.
  defp body(text) do
    text
    |> Chat.segments()
    |> Enum.map(fn
      {:mention, t} ->
        ["<span class=\"font-semibold text-[var(--paper-accent)]\">", escape(t), "</span>"]

      {:text, t} ->
        escape(t)
    end)
    |> Phoenix.HTML.raw()
  end

  defp images(%Message{images: images}) when is_list(images), do: images
  defp images(_message), do: []

  defp escape(t), do: t |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp mine?(m, email), do: is_binary(email) and m.author == email

  attr :author, :string, required: true

  defp avatar(%{author: "bot:" <> bot} = assigns) do
    assigns = assign(assigns, :bot, bot)

    ~H"""
    <img
      src={"/images/team/#{@bot}-avatar-96.jpg"}
      width="96"
      height="96"
      alt=""
      class="size-8 shrink-0 rounded-full border-2 border-[#b4874a] object-cover"
    />
    """
  end

  defp avatar(assigns) do
    ~H"""
    <span
      aria-hidden="true"
      class="grid size-8 shrink-0 place-items-center rounded-full border-2 border-[#b4874a] bg-[#f3dcae] text-sm font-bold text-[#3b2a16]"
    >
      {String.first(author(@author))}
    </span>
    """
  end

  defp author("bot:" <> bot), do: String.capitalize(bot)
  defp author(email), do: TeamOnline.name(email)
end
