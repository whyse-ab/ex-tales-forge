defmodule TalesForgeWeb.AdminLive.LoginLive do
  @moduledoc """
  Admin login page: email magic link or GitHub sign-in.
  """

  use TalesForgeWeb, :live_view

  alias TalesForge.AdminAuth.GitHub

  # Only point at /dev/mailbox when the router actually mounts it.
  @dev_routes Application.compile_env(:ex_tales_forge, :dev_routes, false)

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:admin_email] do
      {:ok, push_navigate(socket, to: ~p"/admin")}
    else
      {:ok,
       assign(socket,
         page_title: "Admin login",
         email: "",
         dev_routes: @dev_routes,
         github_enabled: GitHub.enabled?()
       )}
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
    <div class="admin-shell paper-home min-h-dvh flex items-center justify-center px-4">
      <Layouts.flash_group flash={@flash} />
      <div class="w-full max-w-md rounded-lg border border-[var(--paper-rule)] bg-[var(--paper-panel)] p-6 space-y-4">
        <header class="space-y-1">
          <p class="play-label text-[var(--paper-accent)]">Tales Forge</p>
          <h1 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">Admin login</h1>
          <p class="text-sm text-[var(--paper-muted)]">
            For founders and the Tales Forge team.
          </p>
        </header>

        <div :if={@github_enabled} class="space-y-4">
          <a
            id="github-login"
            href={~p"/admin/auth/github"}
            class="flex w-full items-center justify-center gap-2 rounded border border-[var(--paper-ink)] bg-[var(--paper-ink)] px-3 py-2 font-medium text-[var(--paper-panel)]"
          >
            <svg viewBox="0 0 16 16" class="size-5 shrink-0" fill="currentColor" aria-hidden="true">
              <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z" />
            </svg>
            Sign in with GitHub
          </a>
          <div class="flex items-center gap-3 text-xs text-[var(--paper-muted)]">
            <span class="h-px flex-1 bg-[var(--paper-rule)]"></span>
            or get an email link <span class="h-px flex-1 bg-[var(--paper-rule)]"></span>
          </div>
        </div>

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
            class="w-full rounded bg-[var(--paper-accent)] px-3 py-2 text-[var(--paper-on-accent)] font-medium"
          >
            Send magic link
          </button>
        </form>

        <p :if={@dev_routes} class="text-xs text-[var(--paper-muted)]">
          In development, open
          <.link href="/dev/mailbox" class="underline text-[var(--paper-accent)]">/dev/mailbox</.link>
          to grab the link.
        </p>
      </div>
    </div>
    """
  end
end
