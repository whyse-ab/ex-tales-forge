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
    <header class="play-header shrink-0 px-3 py-1.5 sm:px-6 sm:py-3">
      <div class="flex flex-wrap items-center justify-between gap-x-3 gap-y-0.5 sm:gap-3">
        <div class="flex min-w-0 items-center gap-3 sm:gap-4">
          <.link
            navigate={~p"/"}
            class="play-label shrink-0 text-[var(--paper-accent)] hover:underline"
          >
            Tales Forge
          </.link>
          <h1 class="truncate font-serif text-base font-semibold sm:text-lg text-[var(--paper-ink)]">
            {@session_name}
          </h1>
          <.link
            href={~p"/admin/play/sessions/#{@session_id}"}
            class="play-label shrink-0 text-[var(--paper-muted)] hover:text-[var(--paper-accent)] hover:underline"
          >
            Admin
          </.link>
        </div>
        <dl class="flex flex-wrap items-center gap-x-4 gap-y-0 text-xs sm:gap-x-6 sm:gap-y-1 sm:text-sm">
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
  attr :session_status, :string, default: "active"

  @doc """
  The story column of the play page: the narrative log, the GM's "thinking"
  placeholders, any clarification question, and the action form (text input
  plus the Act button). On phones the input shrinks to the space left beside
  Act, so the button stays on screen down to a 320px viewport.

  When the player scrolled up and new text arrives, the "New text below"
  button shows above the action form. StoryScroll (assets/js/story_scroll.js)
  shows the button, hides it at the end of the story, and scrolls to the end
  when the player selects it. The wrapper is a polite live region, so a
  screen reader reads the button text when it shows.
  """
  @spec narrative_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def narrative_panel(assigns) do
    ~H"""
    <section class="play-panel flex min-h-0 flex-1 flex-col overflow-hidden rounded-lg">
      <div class="border-b border-[var(--paper-rule)] px-3 py-1 sm:px-4 sm:py-2">
        <h2 class="play-label">Story</h2>
      </div>

      <%!-- The GM placeholders sit after the stream container, not inside it: every
           child of a phx-update="stream" element must be a stream item with an id.
           `contents` lets the entries and placeholders share one gap-4 column. --%>
      <%!-- StoryScroll (assets/js/story_scroll.js) keeps the newest text in view. --%>
      <div class="relative flex min-h-0 flex-1 flex-col">
        <div
          id="story-scroll"
          phx-hook="StoryScroll"
          class="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto bg-[var(--paper-margin)] p-3 sm:p-4"
        >
          <div id="narrative-log" class="contents" phx-update="stream">
            <div :for={{dom_id, entry} <- @streams.entries} id={dom_id} class="space-y-1">
              <p class={entry_heading_class(entry)}>
                {entry_heading(entry)}
              </p>
              <div class={entry_body_class(entry)}>
                <span class="play-narrative-body">{entry.text}</span>
              </div>
            </div>
          </div>

          <p :if={@scene_loading} class="text-sm italic text-[var(--paper-muted)]">
            The GM is setting the scene…
          </p>
          <p :if={@thinking} class="text-sm italic text-[var(--paper-muted)]">
            The GM is thinking…
          </p>
        </div>

        <div
          id="story-new-text-region"
          phx-update="ignore"
          aria-live="polite"
          class="pointer-events-none absolute inset-x-0 bottom-2 flex justify-center"
        >
          <button
            id="story-new-text"
            type="button"
            hidden
            aria-controls="story-scroll"
            class="pointer-events-auto rounded-full bg-[var(--paper-accent)] px-3 py-1 text-sm font-medium text-white shadow hover:opacity-90 focus-visible:outline-2 focus-visible:outline-offset-2"
          >
            New text below <span aria-hidden="true">↓</span>
          </button>
        </div>
      </div>

      <div class="shrink-0 space-y-2 border-t border-[var(--paper-rule)] p-2 sm:space-y-3 sm:p-4">
        <p :if={@session_status == "dead"} class="text-sm italic text-[var(--paper-muted)]">
          You are dead.
        </p>
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
              disabled={@input_disabled}
              class="block w-full rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-3 py-2 text-left text-sm hover:bg-[var(--paper-margin)] disabled:opacity-50"
            >
              <span class="font-medium">{opt["label"]}</span>
              <span :if={opt["description"]} class="block text-[var(--paper-muted)]">
                {opt["description"]}
              </span>
            </button>
          </div>
        </section>

        <%!-- min-w-0 lets the input shrink below its intrinsic width (~255px) and
             shrink-0 keeps Act whole, so both fit a 320px phone. --%>
        <.form
          for={%{}}
          id="action-form"
          phx-submit="send_message"
          class="flex w-full min-w-0 items-stretch gap-2"
        >
          <input
            type="text"
            name="message"
            placeholder={input_placeholder(@scene_loading, @session_status)}
            autocomplete="off"
            aria-label="Your action"
            class="min-w-0 flex-1 rounded border border-[var(--paper-rule)] bg-[var(--paper-panel)] px-3 py-2 text-[var(--paper-ink)] placeholder:text-[var(--paper-muted)]"
            disabled={@input_disabled}
          />
          <%!-- While a turn is in flight Act reads "Thinking…" and is disabled;
               phx-disable-with covers the moment before the server answers. --%>
          <button
            type="submit"
            id="act-button"
            class="shrink-0 rounded bg-[var(--paper-accent)] px-4 py-2 font-medium text-white hover:opacity-90 disabled:cursor-wait disabled:opacity-50"
            disabled={@input_disabled}
            aria-busy={to_string(@thinking)}
            phx-disable-with="Thinking…"
          >
            {if @thinking, do: "Thinking…", else: "Act"}
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
    wounds_part = "#{wounds}/#{wound_max} wounds · #{coins}"

    case Map.get(character, "vitality", "ok") do
      "ok" -> wounds_part
      vitality -> "#{vitality} · #{wounds_part}"
    end
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

  defp input_placeholder(_scene_loading, "dead"), do: "You are dead."
  defp input_placeholder(true, _status), do: "Wait for the scene…"
  defp input_placeholder(_, _status), do: "What do you do?"

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
