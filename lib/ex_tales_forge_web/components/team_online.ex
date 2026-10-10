defmodule TalesForgeWeb.TeamOnline do
  @moduledoc """
  "Online now" on `/team` (`#online`): the founders with a page open on
  production or playtest, with the page name, and the bots with their latest
  activity and when it was (`TalesForge.TeamOnline`). One list for both apps.

  A list with plain text, so screen readers read each person in full; the
  green dot has a text twin ("online"). Wraps on a phone.
  """

  use Phoenix.Component

  alias TalesForge.TeamOnline
  alias TalesForgeWeb.TeamArt
  alias TalesForgeWeb.TimeAgo

  attr :online, :map, required: true, doc: "`TalesForge.TeamOnline.snapshot/1`"
  attr :now, DateTime, required: true

  @doc "The section."
  @spec section(map()) :: Phoenix.LiveView.Rendered.t()
  def section(assigns) do
    assigns = assign(assigns, :minutes, TeamOnline.online_minutes())

    ~H"""
    <section id="online" class="space-y-4" aria-labelledby="online-title">
      <header class="max-w-3xl space-y-1">
        <h2 id="online-title" class="font-serif text-2xl font-bold sm:text-3xl">Online now</h2>
        <p class="text-base leading-relaxed text-[var(--paper-muted)]">
          Founders with a page open on production or playtest, and what each bot did last.
        </p>
      </header>

      <ul id="online-founders" class="flex flex-wrap gap-3" aria-label="Founders online">
        <li
          :for={f <- @online.founders}
          id={"online-founder-#{f.app}-#{slug(f.email)}"}
          class="team-card flex min-h-11 items-center gap-3 px-3 py-2"
        >
          <span
            aria-hidden="true"
            class="grid size-9 shrink-0 place-items-center rounded-full border-2 border-[#b4874a] bg-[#f3dcae] font-bold"
          >
            {String.first(f.name)}
          </span>
          <span class="text-sm leading-snug">
            <span class="font-semibold">{f.name}</span>
            <span class="sr-only">, online,</span>
            <span class="block text-[var(--paper-muted)]">{f.page} on {f.app}</span>
          </span>
          <span class="size-2.5 shrink-0 rounded-full bg-green-600" aria-hidden="true"></span>
        </li>
        <li
          :if={@online.founders == []}
          id="online-founders-none"
          class="text-sm text-[var(--paper-muted)]"
        >
          Founders show here when they open a page.
        </li>
      </ul>

      <ul id="online-bots" class="flex flex-wrap gap-3" aria-label="Bots and their latest activity">
        <li
          :for={b <- @online.bots}
          id={"online-bot-#{b.id}"}
          class="team-card flex min-h-11 items-center gap-3 px-3 py-2"
        >
          <TeamArt.avatar id={b.id} class="size-9" label="" />
          <span class="text-sm leading-snug">
            <span class="font-semibold">{b.name}</span>
            <span :if={b.online} class="sr-only">, online,</span>
            <%= if b.at do %>
              <span class="block text-[var(--paper-muted)]">
                {b.doing},
                <time datetime={DateTime.to_iso8601(b.at)} title={TimeAgo.stockholm(b.at)}>
                  last seen {TimeAgo.relative(b.at, @now)}
                </time>
              </span>
            <% else %>
              <span class="block text-[var(--paper-muted)]">No activity since the last deploy</span>
            <% end %>
          </span>
          <span :if={b.online} class="size-2.5 shrink-0 rounded-full bg-green-600" aria-hidden="true"></span>
        </li>
      </ul>
      <p class="text-xs text-[var(--paper-muted)]">
        A bot shows a green dot when its last activity is {@minutes} minutes old or less.
      </p>
    </section>
    """
  end

  defp slug(email), do: email |> String.replace(~r/[^a-z0-9]+/i, "-") |> String.trim("-")
end
