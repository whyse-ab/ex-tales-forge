defmodule TalesForgeWeb.CharacterChangesComponents do
  @moduledoc """
  Admin views of `TalesForge.Playtest.CharacterChanges`: the per-run
  "Character changes" section of the playtest run page (start versus end per
  character, memories added, a per-turn timeline with links to the turns, and
  what is not tracked yet) and the per-batch summary on the playtest runs list.

  Built for the admin's phone layout: characters are collapsible blocks, rows
  stack under their label on narrow screens, and colours come from the
  `--paper-*` variables so dark mode follows the theme.
  """

  use TalesForgeWeb, :html

  alias TalesForge.Playtest.CharacterChanges
  alias TalesForge.Playtest.CharacterChanges.{Character, Field, Summary}

  attr :changes, CharacterChanges, required: true

  @doc "The run page section: one collapsible block per character, the timeline and the notes."
  @spec character_changes(map()) :: Phoenix.LiveView.Rendered.t()
  def character_changes(assigns) do
    ~H"""
    <section
      id="character-changes"
      class="min-w-0 space-y-3 rounded-lg border border-[var(--paper-rule)] bg-[var(--paper-panel)] p-3 sm:p-4"
    >
      <h2 class="font-serif text-lg font-semibold text-[var(--paper-ink)]">Character changes</h2>
      <p class="text-xs text-[var(--paper-muted)]">
        Start of the run → end, for the player character and every NPC, read from the state the
        game stores today. "Not tracked yet" means the game does not store it, so it is not shown.
      </p>
      <p :if={@changes.characters == []} class="text-sm text-[var(--paper-muted)]">
        No characters recorded for this run.
      </p>

      <div class="space-y-2">
        <details
          :for={c <- @changes.characters}
          id={"cc-#{c.slug}"}
          open={c.kind == :pc}
          class="rounded border border-[var(--paper-rule)] bg-[var(--paper-bg)] p-2"
        >
          <summary class="cursor-pointer text-sm">
            <span class="font-semibold text-[var(--paper-ink)]">{c.name}</span>
            <span class="ml-1 rounded border border-[var(--paper-rule)] px-1.5 text-xs text-[var(--paper-muted)]">
              {if c.kind == :pc, do: "player character", else: "NPC"}
            </span>
            <span id={"cc-#{c.slug}-summary"} class="ml-1 text-xs text-[var(--paper-muted)]">
              {summary_line(c)}
            </span>
          </summary>

          <dl class="mt-2 divide-y divide-[var(--paper-rule)]">
            <.field_row :for={f <- c.fields} field={f} slug={c.slug} />
          </dl>

          <details :if={c.memories_added != []} class="mt-2" id={"cc-#{c.slug}-memories"}>
            <summary class="cursor-pointer text-sm text-[var(--paper-ink)]">
              Memories added ({length(c.memories_added)})
            </summary>
            <ol class="mt-1 space-y-1 text-sm">
              <li :for={m <- c.memories_added} class="break-words">
                <.turn_link turn_number={m.turn_number} />
                <span class="text-xs text-[var(--paper-muted)]">
                  · {CharacterChanges.source_label(m.source)}{if m.felt, do: " · felt #{m.felt}"}
                </span>
                <span class="text-[var(--paper-ink)]">{m.text}</span>
              </li>
            </ol>
          </details>

          <div :if={c.not_tracked != []} class="mt-2" id={"cc-#{c.slug}-not-tracked"}>
            <p class="play-label text-[var(--paper-muted)]">Not tracked yet</p>
            <ul class="space-y-1 text-sm">
              <li :for={f <- c.not_tracked} class="break-words">
                <span class="text-[var(--paper-ink)]">
                  {f.label}{if f.start_value, do: ": #{f.start_value}"}
                </span>
                <span class="text-xs italic text-[var(--paper-muted)]">
                  — not tracked yet. {f.note}
                </span>
              </li>
            </ul>
          </div>
        </details>
      </div>

      <div :if={@changes.timeline != []} id="cc-timeline" class="space-y-1">
        <h3 class="play-label text-[var(--paper-muted)]">Per turn</h3>
        <ol class="space-y-2 text-sm">
          <li
            :for={entry <- @changes.timeline}
            id={"cc-turn-#{entry.turn_number || "unknown"}"}
            class="border-t border-[var(--paper-rule)] pt-1"
          >
            <.turn_link turn_number={entry.turn_number} />
            <ul class="mt-0.5 space-y-0.5">
              <li :for={change <- entry.changes} class="break-words">
                <span class="font-medium text-[var(--paper-ink)]">{change.name}</span>
                <span class="text-xs text-[var(--paper-muted)]">· {change.kind}</span>
                <span class="text-[var(--paper-ink)]">{change.text}</span>
              </li>
            </ul>
          </li>
        </ol>
      </div>

      <div :if={@changes.notes != []} id="cc-notes">
        <h3 class="play-label text-[var(--paper-muted)]">What the stored state cannot tell</h3>
        <ul class="list-disc space-y-0.5 pl-5 text-xs text-[var(--paper-muted)]">
          <li :for={note <- @changes.notes}>{note}</li>
        </ul>
      </div>
    </section>
    """
  end

  attr :field, Field, required: true
  attr :slug, :string, required: true

  defp field_row(assigns) do
    ~H"""
    <div
      id={"cc-#{@slug}-field-#{@field.key}"}
      class="grid gap-x-3 py-1 text-sm sm:grid-cols-[minmax(8rem,14rem)_1fr]"
    >
      <dt class="text-[var(--paper-muted)]">{@field.label}</dt>
      <dd class="min-w-0 break-words">
        <%= case @field.status do %>
          <% :changed -> %>
            <span class="text-[var(--paper-muted)]">{@field.start_value || "—"}</span>
            <span aria-label="became">→</span>
            <span class="font-semibold text-[var(--paper-ink)]">{@field.end_value || "—"}</span>
          <% :unchanged -> %>
            <span class="text-[var(--paper-ink)]">{@field.end_value || "—"}</span>
            <span class="text-xs text-[var(--paper-muted)]">(no change)</span>
          <% :not_tracked -> %>
            <span class="text-xs italic text-[var(--paper-muted)]">not tracked yet</span>
        <% end %>
        <span :if={@field.note} class="block text-xs text-[var(--paper-muted)]">{@field.note}</span>
        <span class="block text-xs text-[var(--paper-muted)] opacity-80">from {@field.source}</span>
      </dd>
    </div>
    """
  end

  attr :turn_number, :any, required: true

  defp turn_link(%{turn_number: nil} = assigns) do
    ~H"""
    <span class="text-xs text-[var(--paper-muted)]">turn unknown</span>
    """
  end

  defp turn_link(assigns) do
    ~H"""
    <a href={"#turn-#{@turn_number}"} class="text-xs font-medium text-[var(--paper-accent)]">
      Turn {@turn_number}
    </a>
    """
  end

  defp summary_line(%Character{} = c) do
    changed = Enum.count(c.fields, &(&1.status == :changed))

    case {changed, length(c.memories_added)} do
      {0, 0} -> "no recorded change"
      {f, 0} -> "#{f} changed"
      {0, m} -> "#{m} memories added"
      {f, m} -> "#{f} changed · #{m} memories added"
    end
  end

  attr :batches, :list, required: true

  @doc """
  The runs-list section: per batch, the share of runs where an NPC's attitude
  toward the player character changed, memories added per run and NPCs with
  any change per run.
  """
  @spec batch_character_changes(map()) :: Phoenix.LiveView.Rendered.t()
  def batch_character_changes(assigns) do
    ~H"""
    <section
      id="batch-character-changes"
      class="min-w-0 space-y-3 rounded-lg border border-[var(--paper-rule)] bg-[var(--paper-panel)] p-3 sm:p-4"
    >
      <h2 class="font-serif text-lg font-semibold text-[var(--paper-ink)]">
        Character changes by batch
      </h2>
      <p :if={@batches == []} class="text-sm text-[var(--paper-muted)]">
        No finished runs with played turns yet.
      </p>
      <ul class="divide-y divide-[var(--paper-rule)]">
        <li :for={{b, i} <- Enum.with_index(@batches)} id={"batch-#{i}"} class="space-y-1 py-2">
          <p class="text-sm">
            <span class="font-semibold text-[var(--paper-ink)]">{b.label}</span>
            <span class="text-[var(--paper-muted)]">· {b.summary.runs} runs</span>
          </p>
          <dl class="flex flex-wrap gap-x-5 gap-y-1 text-sm">
            <div>
              <dt class="inline text-[var(--paper-muted)]">NPC attitude to PC changed</dt>
              <dd class="inline font-medium tabular-nums">{attitude(b.summary)}</dd>
            </div>
            <div>
              <dt class="inline text-[var(--paper-muted)]">NPCs whose attitude changed / run</dt>
              <dd class="inline font-medium tabular-nums">
                {median_mean(b.summary.attitude_npcs_median, b.summary.attitude_npcs_mean)}
              </dd>
            </div>
            <div>
              <dt class="inline text-[var(--paper-muted)]">Memories / run</dt>
              <dd class="inline font-medium tabular-nums">
                {median_mean(b.summary.memories_median, b.summary.memories_mean)}
              </dd>
            </div>
            <div>
              <dt class="inline text-[var(--paper-muted)]">NPCs changed / run</dt>
              <dd class="inline font-medium tabular-nums">
                {median_mean(b.summary.npcs_changed_median, b.summary.npcs_changed_mean)}
              </dd>
            </div>
          </dl>
        </li>
      </ul>
      <p class="text-xs text-[var(--paper-muted)]">
        Attitude changed: some NPC's latest Jev stance toward the player character is not neutral,
        or its relationship score moved off 0 (stance only in runs with NPC reactions on).
        Memories: memories any NPC gained during the run. NPCs changed: NPCs with any stored change
        (memory, mood, stance, relationship, location or concern). Per-run figures are median · mean.
        Runs that are not still running and played at least one turn.
      </p>
    </section>
    """
  end

  defp attitude(%Summary{attitude_changed_share: nil}), do: "—"

  defp attitude(%Summary{} = s) do
    pct = :erlang.float_to_binary(s.attitude_changed_share * 100, decimals: 0)

    "#{pct}% (#{s.attitude_changed}/#{s.runs}; stance #{s.stance_changed}, " <>
      "relationship #{s.relationship_changed})"
  end

  defp median_mean(nil, _mean), do: "—"

  defp median_mean(median, mean),
    do: "#{fmt(median)} · #{fmt(mean)}"

  defp fmt(x) when is_float(x) do
    if x == Float.round(x),
      do: x |> trunc() |> Integer.to_string(),
      else: :erlang.float_to_binary(x, decimals: 1)
  end
end
