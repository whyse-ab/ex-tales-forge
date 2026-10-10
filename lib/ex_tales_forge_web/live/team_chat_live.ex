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
  - Phone: the panel fills the screen; from `sm` up it is a side panel.
  """

  use TalesForgeWeb, :live_view

  alias Phoenix.LiveView.JS
  alias TalesForge.Chat
  alias TalesForge.Chat.Message
  alias TalesForge.TeamOnline
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
     |> assign(:me, Chat.handle_for(login))
     |> assign(:open, false)
     |> assign(:draft, "")
     |> assign(:messages, [])
     |> assign(:unread, Chat.unread(login))
     |> assign(:form, to_form(%{"body" => ""}, as: :chat)), layout: false}
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("open", _params, socket), do: {:noreply, open(socket, nil)}
  def handle_event("close", _params, socket), do: {:noreply, assign(socket, :open, false)}

  def handle_event("send", %{"chat" => %{"body" => body}}, socket) do
    case Chat.post(socket.assigns.admin_email, body, login: socket.assigns.login) do
      {:ok, _message} ->
        {:noreply, assign(socket, :form, to_form(%{"body" => ""}, as: :chat))}

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

      <div
        :if={@open}
        id={"#{@id_prefix}-panel"}
        role="dialog"
        aria-modal="true"
        aria-labelledby={"#{@id_prefix}-title"}
        phx-window-keydown={JS.push("close") |> JS.focus(to: "##{@id_prefix}-button")}
        phx-key="Escape"
        class="fixed inset-0 z-50 flex flex-col bg-[var(--paper-panel)] text-left text-[var(--paper-ink)] shadow-xl sm:inset-y-0 sm:left-auto sm:right-0 sm:w-96 sm:border-l sm:border-[var(--paper-rule)]"
      >
        <div class="flex items-center justify-between gap-2 border-b border-[var(--paper-rule)] px-4 py-3">
          <h2 id={"#{@id_prefix}-title"} class="font-serif text-lg font-semibold">Team chat</h2>
          <button
            id={"#{@id_prefix}-close"}
            type="button"
            phx-click={JS.push("close") |> JS.focus(to: "##{@id_prefix}-button")}
            class="inline-flex min-h-11 min-w-11 items-center justify-center rounded-full hover:bg-[var(--paper-bg)]"
          >
            <.icon name="hero-x-mark" class="size-5" /><span class="sr-only">Close the chat</span>
          </button>
        </div>

        <ol
          id={"#{@id_prefix}-messages"}
          aria-live="polite"
          aria-label="Messages"
          class="flex-1 space-y-3 overflow-y-auto px-4 py-3"
        >
          <li :if={@messages == []} class="text-sm text-[var(--paper-muted)]">
            Write the first message. Everyone on the team sees it.
          </li>
          <li
            :for={m <- @messages}
            id={"#{@id_prefix}-msg-#{m.id}"}
            class={[
              "rounded-lg px-3 py-2 text-sm leading-relaxed",
              if(@me && @me in m.mentions,
                do: "bg-[var(--paper-bg)] ring-1 ring-[var(--paper-accent)]",
                else: "bg-[var(--paper-bg)]/60"
              )
            ]}
          >
            <p class="flex flex-wrap items-baseline gap-x-2">
              <span class="font-semibold">{author(m.author)}</span>
              <time
                datetime={DateTime.to_iso8601(m.inserted_at)}
                class="text-xs text-[var(--paper-muted)]"
              >
                {TimeAgo.stockholm(m.inserted_at, "%d %b %H:%M")}
              </time>
              <span
                :if={@me && @me in m.mentions}
                class="text-xs font-semibold text-[var(--paper-accent)]"
              >Mentions you</span>
            </p>
            <p class="whitespace-pre-wrap break-words">
              <%= for {kind, text} <- Chat.segments(m.body) do %>
                <span :if={kind == :mention} class="font-semibold text-[var(--paper-accent)]">{text}</span><span :if={
                  kind == :text
                }>{text}</span>
              <% end %>
            </p>
          </li>
        </ol>

        <.form
          for={@form}
          id={"#{@id_prefix}-form"}
          phx-submit="send"
          class="space-y-2 border-t border-[var(--paper-rule)] px-4 py-3"
        >
          <label for={"#{@id_prefix}-body"} class="block text-sm font-semibold">Message</label>
          <textarea
            id={"#{@id_prefix}-body"}
            name="chat[body]"
            rows="3"
            maxlength={Message.max_length()}
            phx-mounted={JS.focus()}
            aria-describedby={"#{@id_prefix}-hint"}
            class="w-full rounded border border-[var(--paper-rule)] bg-[var(--paper-bg)] p-2 text-base"
          >{Phoenix.HTML.Form.normalize_value("textarea", @form[:body].value)}</textarea>
          <p
            :for={msg <- Enum.map(@form[:body].errors, &elem(&1, 0))}
            class="text-sm text-red-700"
            role="alert"
          >
            {msg}
          </p>
          <p id={"#{@id_prefix}-hint"} class="text-xs text-[var(--paper-muted)]">
            Mention someone with @: {Enum.map_join(Chat.suggestions(), ", ", &("@" <> &1))}. A founder's mention of a bot wakes that bot.
          </p>
          <button
            type="submit"
            class="team-cta inline-flex min-h-11 items-center gap-2 rounded-full px-5 py-2 font-semibold"
          >
            Send
          </button>
        </.form>
      </div>
    </div>
    """
  end

  defp author("bot:" <> bot), do: String.capitalize(bot)
  defp author(email), do: TeamOnline.name(email)
end
