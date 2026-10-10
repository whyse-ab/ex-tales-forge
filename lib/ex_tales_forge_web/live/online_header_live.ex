defmodule TalesForgeWeb.OnlineHeaderLive do
  @moduledoc """
  Who's online, in the header of every admin page (`Layouts.admin`) and of
  `/team` and the presentation (`TalesForgeWeb.TeamLayout.header/1`): a compact
  counter "Founders: 2 Bots: 2" that opens a list.

  - Founders: everyone with a page open on production or playtest
    (`TalesForge.Online`), with the page they are on.
  - Bots: counted when their latest activity is 10 minutes old or less
    (`TalesForge.TeamOnline.online_minutes/0`); the list shows every bot with
    that activity and its time.
  - Each entry has a "Chat" button, disabled, "Coming with team chat", while
    config `:team_chat_placeholder` is true (`TalesForge.Online.chat_placeholder?/0`).

  A nested LiveView, so updates patch only the header. Accessible: the
  counter is a button with `aria-expanded` and `aria-controls`; opening it
  moves focus to the list, Esc closes it and moves focus back to the button,
  and a click outside closes it. On a phone the list fits the screen width.
  """

  use TalesForgeWeb, :live_view

  alias Phoenix.LiveView.JS
  alias TalesForge.Online
  alias TalesForgeWeb.TimeAgo

  @refresh_ms 30_000

  @impl true
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t(), keyword()}
  def mount(_params, session, socket) do
    if connected?(socket) do
      Online.subscribe()
      Process.send_after(self(), :tick, @refresh_ms)
    end

    {:ok,
     socket
     |> assign(:id_prefix, session["id_prefix"] || "online")
     |> assign(:open, false)
     |> assign(:chat?, Online.chat_placeholder?())
     |> load(), layout: false}
  end

  defp load(socket) do
    now = DateTime.utc_now()
    snap = Online.snapshot(now)
    founders = snap.founders

    assign(socket,
      now: now,
      founders: founders,
      bots: snap.bots,
      founder_count: founders |> Enum.uniq_by(& &1.email) |> length(),
      bot_count: Enum.count(snap.bots, & &1[:online])
    )
  end

  @impl true
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event("toggle", _params, socket),
    do: {:noreply, socket |> load() |> assign(:open, !socket.assigns.open)}

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, :open, false)}

  @impl true
  @spec handle_info(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @refresh_ms)
    {:noreply, load(socket)}
  end

  def handle_info({:online, :changed}, socket), do: {:noreply, load(socket)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, load(socket)}

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div
      id={"#{@id_prefix}-presence"}
      class="relative"
      phx-click-away={@open && JS.push("close")}
      phx-keydown={@open && JS.push("close") |> JS.focus(to: "##{@id_prefix}-toggle")}
      phx-key="Escape"
    >
      <button
        id={"#{@id_prefix}-toggle"}
        type="button"
        phx-click="toggle"
        aria-expanded={to_string(@open)}
        aria-controls={"#{@id_prefix}-list"}
        aria-haspopup="true"
        class="inline-flex min-h-9 items-center gap-1.5 rounded-full border border-[var(--paper-rule)] px-2.5 py-1 text-xs font-semibold text-[var(--paper-ink)] hover:bg-[var(--paper-bg)] focus-visible:outline-2 focus-visible:outline-[var(--paper-accent)] sm:text-sm"
      >
        <span class="size-2 rounded-full bg-green-600" aria-hidden="true"></span>
        <span>Founders: {@founder_count}</span>
        <span>Bots: {@bot_count}</span>
        <span class="sr-only">online. Show who is online.</span>
      </button>

      <div
        :if={@open}
        id={"#{@id_prefix}-list"}
        role="region"
        aria-label="Who is online"
        tabindex="-1"
        phx-mounted={JS.focus()}
        class="fixed inset-x-3 top-16 z-40 max-h-[70dvh] sm:absolute sm:inset-x-auto sm:right-0 sm:top-auto sm:mt-2 sm:w-80 overflow-y-auto rounded-lg border border-[var(--paper-rule)] bg-[var(--paper-panel)] p-2 text-left shadow-lg"
      >
        <h2 class="px-2 pb-1 text-xs font-semibold uppercase tracking-wide text-[var(--paper-muted)]">
          Founders
        </h2>
        <ul id={"#{@id_prefix}-founders"} class="space-y-1">
          <li
            :for={f <- @founders}
            id={"#{@id_prefix}-founder-#{f.app}-#{slug(f.email)}"}
            class="flex items-center gap-2 rounded px-2 py-1.5"
          >
            <span
              aria-hidden="true"
              class="grid size-8 shrink-0 place-items-center rounded-full border-2 border-[#b4874a] bg-[#f3dcae] text-sm font-bold text-[#3b2a16]"
            >
              {String.first(f.name)}
            </span>
            <span class="min-w-0 flex-1 text-sm leading-snug">
              <span class="block font-semibold">{f.name}</span>
              <span class="block truncate text-[var(--paper-muted)]">{f.page} on {f.app}</span>
            </span>
            <.chat :if={@chat?} who={f.name} />
          </li>
          <li :if={@founders == []} class="px-2 py-1.5 text-sm text-[var(--paper-muted)]">
            Founders show here when they open a page.
          </li>
        </ul>

        <h2
          :if={@bots != []}
          class="mt-2 px-2 pb-1 text-xs font-semibold uppercase tracking-wide text-[var(--paper-muted)]"
        >
          Bots
        </h2>
        <ul :if={@bots != []} id={"#{@id_prefix}-bots"} class="space-y-1">
          <li
            :for={b <- @bots}
            id={"#{@id_prefix}-bot-#{b.id}"}
            class="flex items-center gap-2 rounded px-2 py-1.5"
          >
            <img
              src={"/images/team/#{b.id}-avatar-96.jpg"}
              width="96"
              height="96"
              alt=""
              loading="lazy"
              class="size-8 shrink-0 rounded-full border-2 border-[#b4874a] object-cover"
            />
            <span class="min-w-0 flex-1 text-sm leading-snug">
              <span class="block font-semibold">
                {b.name}<span :if={b.online} class="sr-only">, active</span>
                <span
                  :if={b.online}
                  class="ml-1 inline-block size-2 rounded-full bg-green-600"
                  aria-hidden="true"
                ></span>
              </span>
              <span :if={b.at} class="block text-[var(--paper-muted)]">
                {b.doing},
                <time datetime={DateTime.to_iso8601(b.at)} title={TimeAgo.stockholm(b.at)}>{TimeAgo.relative(
                  b.at,
                  @now
                )}</time>
              </span>
              <span :if={!b.at} class="block text-[var(--paper-muted)]">No activity since the last deploy</span>
            </span>
            <.chat :if={@chat?} who={b.name} />
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :who, :string, required: true

  defp chat(assigns) do
    ~H"""
    <button
      type="button"
      disabled
      aria-disabled="true"
      aria-label={"Chat with #{@who}: coming with team chat"}
      title="Coming with team chat"
      class="shrink-0 cursor-not-allowed rounded-full border border-[var(--paper-rule)] px-2 py-1 text-xs text-[var(--paper-muted)] opacity-70"
    >
      Chat
    </button>
    """
  end

  defp slug(email), do: email |> String.replace(~r/[^a-z0-9]+/i, "-") |> String.trim("-")
end
