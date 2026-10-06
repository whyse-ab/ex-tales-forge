defmodule TalesForgeWeb.AdminLive.LoginLive do
  use TalesForgeWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:admin_email] do
      {:ok, push_navigate(socket, to: ~p"/admin")}
    else
      {:ok, assign(socket, page_title: "Admin login", email: "")}
    end
  end

  @impl true
  def handle_event("submit", %{"email" => email}, socket) do
    # Use the controller path so the POST is a normal request sending mail.
    # LiveView just validates shape; actual send goes through the form action.
    {:noreply, assign(socket, email: email)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="paper-home min-h-dvh flex items-center justify-center px-4">
      <div class="w-full max-w-md rounded-lg border border-[var(--paper-rule)] bg-[var(--paper-panel)] p-6 space-y-4">
        <header class="space-y-1">
          <p class="play-label text-[var(--paper-accent)]">Tales Forge</p>
          <h1 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">Admin login</h1>
          <p class="text-sm text-[var(--paper-muted)]">
            Email magic link for allowlisted founders. No GitHub required.
          </p>
        </header>

        <form action={~p"/admin/login"} method="post" class="space-y-3">
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <label class="block space-y-1">
            <span class="play-label text-[var(--paper-muted)]">Email</span>
            <input
              type="email"
              name="email"
              required
              value={@email}
              class="w-full rounded border border-[var(--paper-rule)] bg-[var(--paper-bg)] px-3 py-2 text-[var(--paper-ink)]"
              placeholder="you@example.com"
            />
          </label>
          <button
            type="submit"
            class="w-full rounded bg-[var(--paper-accent)] px-3 py-2 text-white font-medium"
          >
            Send magic link
          </button>
        </form>

        <p class="text-xs text-[var(--paper-muted)]">
          In development, open
          <.link href="/dev/mailbox" class="underline text-[var(--paper-accent)]">/dev/mailbox</.link>
          to grab the link.
        </p>
      </div>
    </div>
    """
  end
end
