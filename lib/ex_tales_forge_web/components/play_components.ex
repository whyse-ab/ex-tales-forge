defmodule TalesForgeWeb.PlayComponents do
  @moduledoc false
  use TalesForgeWeb, :html

  attr :session_id, :string, required: true
  attr :session_name, :string, required: true
  attr :world_clock, :string, required: true
  attr :location_name, :string, required: true
  attr :quick_stats, :string, required: true

  def play_header(assigns) do
    ~H"""
    <header class="play-header shrink-0 px-4 py-3 sm:px-6">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div class="flex min-w-0 items-center gap-4">
          <.link
            navigate={~p"/"}
            class="play-label shrink-0 text-[var(--paper-accent)] hover:underline"
          >
            Tales Forge
          </.link>
          <h1 class="truncate font-serif text-lg font-semibold text-[var(--paper-ink)]">
            {@session_name}
          </h1>
          <.link
            href={~p"/admin/sessions/#{@session_id}"}
            class="play-label shrink-0 text-[var(--paper-muted)] hover:text-[var(--paper-accent)] hover:underline"
          >
            Admin
          </.link>
        </div>
        <dl class="flex flex-wrap items-center gap-x-6 gap-y-1 text-sm">
          <div class="flex items-baseline gap-2">
            <dt class="play-label">Time</dt>
            <dd class="font-medium text-[var(--paper-ink)]">{@world_clock}</dd>
          </div>
          <div class="flex items-baseline gap-2">
            <dt class="play-label">Location</dt>
            <dd class="font-medium text-[var(--paper-ink)]">{@location_name}</dd>
          </div>
          <div class="flex items-baseline gap-2">
            <dt class="play-label">Status</dt>
            <dd class="font-medium text-[var(--paper-ink)]">{@quick_stats}</dd>
          </div>
        </dl>
      </div>
    </header>
    """
  end

  attr :streams, :map, required: true
  attr :scene_loading, :boolean, required: true
  attr :thinking, :boolean, required: true
  attr :clarification, :map, default: nil
  attr :input_disabled, :boolean, required: true

  def narrative_panel(assigns) do
    ~H"""
    <section class="play-panel flex min-h-0 flex-1 flex-col overflow-hidden rounded-lg">
      <div class="border-b border-[var(--paper-rule)] px-4 py-2">
        <h2 class="play-label">Story</h2>
      </div>

      <div
        id="narrative-log"
        class="min-h-0 flex-1 space-y-4 overflow-y-auto bg-[var(--paper-margin)] p-4"
        phx-update="stream"
      >
        <div :for={{dom_id, entry} <- @streams.entries} id={dom_id} class="space-y-1">
          <p class={entry_heading_class(entry)}>
            {entry_heading(entry)}
          </p>
          <div class={entry_body_class(entry)}>
            <span class="play-narrative-body">{entry.text}</span>
          </div>
        </div>

        <p :if={@scene_loading} class="text-sm italic text-[var(--paper-muted)]">
          The GM is setting the scene…
        </p>
        <p :if={@thinking} class="text-sm italic text-[var(--paper-muted)]">
          The GM is thinking…
        </p>
      </div>

      <div class="shrink-0 space-y-3 border-t border-[var(--paper-rule)] p-4">
        <section
          :if={@clarification}
          class="rounded-lg border border-[var(--paper-rule)] bg-[var(--paper-bg)] p-3"
        >
          <p class="mb-2 text-sm font-medium text-[var(--paper-ink)]">{@clarification["question"]}</p>
          <div class="space-y-2">
            <button
              :for={opt <- @clarification["options"]}
              type="button"
              phx-click="pick_clarification"
              phx-value-option_id={opt["id"]}
              class="block w-full rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-3 py-2 text-left text-sm hover:bg-[var(--paper-margin)]"
            >
              <span class="font-medium">{opt["label"]}</span>
              <span :if={opt["description"]} class="block text-[var(--paper-muted)]">
                {opt["description"]}
              </span>
            </button>
          </div>
        </section>

        <.form for={%{}} phx-submit="send_message" class="flex gap-2">
          <input
            type="text"
            name="message"
            placeholder={if @scene_loading, do: "Wait for the scene…", else: "What do you do?"}
            autocomplete="off"
            class="flex-1 rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-3 py-2 text-[var(--paper-ink)] placeholder:text-[var(--paper-muted)]"
            disabled={@input_disabled}
          />
          <button
            type="submit"
            class="rounded bg-[var(--paper-accent)] px-4 py-2 font-medium text-white hover:opacity-90 disabled:opacity-50"
            disabled={@input_disabled}
          >
            Act
          </button>
        </.form>
      </div>
    </section>
    """
  end

  attr :location_name, :string, required: true
  attr :scene_image_url, :string, default: nil
  attr :present_npcs, :list, required: true

  def visual_panel(assigns) do
    ~H"""
    <section class="play-panel flex min-h-0 flex-1 flex-col overflow-hidden rounded-lg lg:max-w-md">
      <div class="border-b border-[var(--paper-rule)] px-4 py-2">
        <h2 class="play-label">Visuals</h2>
      </div>

      <div class="min-h-0 flex-1 space-y-4 overflow-y-auto p-4">
        <div class="overflow-hidden rounded-lg border border-[var(--paper-rule)]">
          <img
            :if={@scene_image_url}
            src={@scene_image_url}
            alt={@location_name}
            class="aspect-video w-full object-cover"
          />
          <div
            :if={!@scene_image_url}
            class="flex aspect-video flex-col items-center justify-center bg-[var(--paper-margin)] px-4 text-center"
          >
            <span class="play-label">Scene</span>
            <span class="mt-1 font-serif text-base font-medium text-[var(--paper-ink)]">
              {@location_name}
            </span>
          </div>
        </div>

        <div>
          <h3 class="play-label mb-2">Present</h3>
          <ul :if={@present_npcs != []} class="grid grid-cols-2 gap-2">
            <li
              :for={npc <- @present_npcs}
              class="flex items-center gap-2 rounded-lg border border-[var(--paper-rule)] bg-[var(--paper-panel)] p-2"
            >
              <.npc_avatar npc={npc} />
              <div class="min-w-0">
                <p class="truncate text-sm font-medium text-[var(--paper-ink)]">{npc.name}</p>
                <p class="truncate text-xs text-[var(--paper-muted)]">
                  {npc_role_label(npc)}
                </p>
              </div>
            </li>
          </ul>
          <p :if={@present_npcs == []} class="text-sm text-[var(--paper-muted)]">No one nearby.</p>
        </div>
      </div>
    </section>
    """
  end

  attr :npc, :map, required: true

  defp npc_avatar(assigns) do
    ~H"""
    <div class="flex h-10 w-10 shrink-0 items-center justify-center overflow-hidden rounded-full border border-[var(--paper-rule)] bg-[var(--paper-margin)]">
      <img
        :if={@npc.portrait_url}
        src={@npc.portrait_url}
        alt={@npc.name}
        class="h-full w-full object-cover"
      />
      <span
        :if={!@npc.portrait_url}
        class="text-xs font-semibold uppercase text-[var(--paper-muted)]"
      >
        {npc_initials(@npc.name)}
      </span>
    </div>
    """
  end

  attr :character, :map, required: true

  def state_panel(assigns) do
    ~H"""
    <section class="play-panel shrink-0 rounded-lg px-4 py-3 sm:px-6">
      <h2 class="play-label mb-3">Character &amp; gear</h2>
      <div class="grid gap-4 sm:grid-cols-2">
        <div class="space-y-2">
          <p class="font-serif text-base font-semibold text-[var(--paper-ink)]">
            {Map.get(@character, "name", "—")}
          </p>
          <p class="text-sm capitalize text-[var(--paper-muted)]">
            {Map.get(@character, "race", "unknown")}
          </p>
          <div class="space-y-1">
            <div class="flex justify-between text-xs text-[var(--paper-muted)]">
              <span>Wounds</span>
              <span>
                {Map.get(@character, "wounds", 0)}/{Map.get(@character, "wound_max", 3)}
              </span>
            </div>
            <div class="h-2 overflow-hidden rounded-full bg-[var(--paper-margin)]">
              <div
                class="h-full rounded-full bg-[var(--paper-accent)]"
                style={"width: #{wound_percent(@character)}%"}
              />
            </div>
          </div>
          <p class="text-sm text-[var(--paper-ink)]">
            <span class="play-label">Coins</span>
            {format_coins(Map.get(@character, "coins", %{}))}
          </p>
        </div>

        <div>
          <h3 class="play-label mb-2">Inventory</h3>
          <ul class="space-y-1 text-sm text-[var(--paper-ink)]">
            <li :for={item <- Map.get(@character, "inventory", [])}>
              {Map.get(item, "name", "item")}
              <span :if={Map.get(item, "quantity", 1) > 1} class="text-[var(--paper-muted)]">
                ×{Map.get(item, "quantity")}
              </span>
            </li>
            <li :if={Map.get(@character, "inventory", []) == []} class="text-[var(--paper-muted)]">
              Empty pack
            </li>
          </ul>
        </div>
      </div>
    </section>
    """
  end

  def present_npcs(world_state) when is_map(world_state) do
    npc_ids = Map.get(world_state, "present_npcs", [])
    npc_state = Map.get(world_state, "npc_state", %{})

    Enum.map(npc_ids, fn npc_id ->
      detail = Map.get(npc_state, npc_id, %{})

      %{
        id: npc_id,
        name: Map.get(detail, "name", npc_id),
        role: Map.get(detail, "role", "present"),
        concern_priority: Map.get(detail, "concern_priority", 0),
        portrait_url: Map.get(detail, "portrait_url")
      }
    end)
  end

  def quick_stats(character) when is_map(character) do
    wounds = Map.get(character, "wounds", 0)
    wound_max = Map.get(character, "wound_max", 3)
    coins = format_coins(Map.get(character, "coins", %{}))
    "#{wounds}/#{wound_max} wounds · #{coins}"
  end

  def entry_heading(%{role: "scene", location_name: name}), do: "You arrive at #{name}"
  def entry_heading(%{role: "gm"}), do: "Game Master"
  def entry_heading(%{role: "player"}), do: "You"
  def entry_heading(%{role: "npc", npc_name: name}) when is_binary(name), do: name
  def entry_heading(_), do: "Narrator"

  defp entry_heading_class(%{role: "scene"}),
    do: "play-label text-[var(--paper-accent)]"

  defp entry_heading_class(%{role: "gm"}),
    do: "play-label text-[var(--paper-ink)]"

  defp entry_heading_class(%{role: "player"}),
    do: "play-label text-[var(--paper-muted)]"

  defp entry_heading_class(%{role: "npc"}),
    do: "play-label font-medium text-[var(--paper-accent)]"

  defp entry_heading_class(_), do: "play-label"

  defp entry_body_class(%{role: "scene"}),
    do:
      "whitespace-pre-wrap rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-3 py-2 text-sm text-[var(--paper-ink)] shadow-sm"

  defp entry_body_class(%{role: "gm"}),
    do:
      "whitespace-pre-wrap rounded bg-[var(--paper-panel)] px-3 py-2 text-sm text-[var(--paper-ink)] shadow-sm"

  defp entry_body_class(%{role: "player"}),
    do:
      "whitespace-pre-wrap rounded border border-[var(--paper-rule)] bg-[var(--paper-bg)] px-3 py-2 text-sm text-[var(--paper-ink)]"

  defp entry_body_class(%{role: "npc"}),
    do:
      "whitespace-pre-wrap rounded border border-[var(--paper-accent)]/30 bg-[var(--paper-panel)] px-3 py-2 text-sm italic text-[var(--paper-ink)] shadow-sm"

  defp entry_body_class(_),
    do:
      "whitespace-pre-wrap rounded bg-[var(--paper-panel)] px-3 py-2 text-sm text-[var(--paper-ink)]"

  def format_mechanical(_), do: nil

  def format_coins(coins) when is_map(coins) do
    gold = Map.get(coins, "gold", 0)
    silver = Map.get(coins, "silver", 0)
    copper = Map.get(coins, "copper", 0)
    "#{gold}g #{silver}s #{copper}c"
  end

  def format_coins(_), do: "—"

  defp wound_percent(character) do
    wounds = Map.get(character, "wounds", 0)
    wound_max = max(Map.get(character, "wound_max", 3), 1)
    wounds |> Kernel.*(100) |> div(wound_max) |> min(100)
  end

  defp npc_initials(name) when is_binary(name) do
    name
    |> String.split()
    |> Enum.take(2)
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
  end

  defp npc_initials(_), do: "?"

  defp npc_role_label(%{concern_priority: priority, role: role})
       when is_integer(priority) and priority >= 8 do
    "#{role} · troubled"
  end

  defp npc_role_label(%{role: role}), do: role
end
