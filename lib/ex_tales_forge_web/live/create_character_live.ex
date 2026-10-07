defmodule TalesForgeWeb.CreateCharacterLive do
  @moduledoc """
  Player character creation screen (`/new/:adventure`), step 2 of the creation
  port (tales-forge-docs `docs/character-creation-port.md`).

  Three steps on one LiveView: race and class, then the 75-point stat buy with
  the race bonus choices, then a typed name and "Begin adventure", which starts
  a session with the created character in place of Elara. All rules live in
  `TalesForge.CharacterCreation`; this module only keeps the draft and renders
  it. Creation makes no AI calls, so it costs nothing (the first character is
  free). The draft lives in the LiveView process and is lost on reload.
  """

  use TalesForgeWeb, :live_view

  alias TalesForge.CharacterCreation, as: CC
  alias TalesForge.GameSessions

  @adventures %{"tin_valley" => "Tin Valley", "crossroads_ledger" => "Crossroads Hamlet"}
  @steps [{"origin", "Race & class"}, {"stats", "Stats"}, {"name", "Name"}]
  @later ["Background", "Standing", "Origin", "Occupation", "Personality & concerns", "AI assist"]
  @stats [
    {"STR", "Strength"},
    {"DEX", "Dexterity"},
    {"CON", "Constitution"},
    {"INT", "Intelligence"},
    {"WIS", "Wisdom"},
    {"CHA", "Charisma"}
  ]

  @doc "Adventures a character can be created for, id to display name."
  @spec adventures() :: %{String.t() => String.t()}
  def adventures, do: @adventures

  @impl true
  def mount(%{"adventure" => adventure}, _session, socket) do
    case Map.fetch(@adventures, adventure) do
      {:ok, adventure_name} ->
        {:ok,
         socket
         |> assign(:page_title, "Create a character · #{adventure_name}")
         |> assign(:adventure, adventure)
         |> assign(:adventure_name, adventure_name)
         |> assign(:options, CC.options(adventure))
         |> assign(:draft, CC.new(adventure))
         |> assign(:step, "origin")
         |> assign(:name_error, nil)
         |> assign(:refused, nil)}

      :error ->
        {:ok, socket |> put_flash(:error, "Unknown adventure.") |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("race", %{"id" => race}, socket),
    do: update_draft(socket, CC.choose_race(socket.assigns.draft, race))

  def handle_event("class", %{"id" => class}, socket),
    do: update_draft(socket, CC.choose_class(socket.assigns.draft, class))

  def handle_event("stat", %{"stat" => stat, "delta" => delta}, socket) do
    draft = socket.assigns.draft
    value = Map.get(draft.base_stats, stat, 0) + String.to_integer(delta)
    update_draft(socket, CC.set_stat(draft, stat, value))
  end

  def handle_event("pick", %{"stat" => stat}, socket) do
    draft = socket.assigns.draft
    count = race_choice(socket.assigns.options, draft.race)["count"]
    update_draft(socket, CC.pick_race_bonus(draft, next_picks(draft.race_picks, stat, count)))
  end

  def handle_event("name", %{"name" => name}, socket) do
    case CC.set_name(socket.assigns.draft, name) do
      {:ok, draft} -> {:noreply, assign(socket, draft: draft, name_error: nil)}
      {:error, {:name, message}} -> {:noreply, assign(socket, :name_error, sentence(message))}
    end
  end

  def handle_event("go", %{"step" => step}, socket) do
    if step_open?(step, socket.assigns.draft),
      do: {:noreply, assign(socket, step: step, refused: nil)},
      else: {:noreply, socket}
  end

  def handle_event("begin", %{"name" => name}, socket) do
    with {:ok, draft} <- name_result(CC.set_name(socket.assigns.draft, name)),
         {:ok, character} <- CC.finalize(draft) do
      start(socket, draft, character)
    else
      {:error, errors} -> {:noreply, show_finalize_errors(socket, errors)}
    end
  end

  defp name_result({:ok, draft}), do: {:ok, draft}
  defp name_result({:error, error}), do: {:error, [error]}

  defp start(socket, draft, character) do
    attrs = %{
      adventure_id: socket.assigns.adventure,
      name: "#{socket.assigns.adventure_name} · #{draft.name}",
      character: character
    }

    case GameSessions.create_session(attrs) do
      {:ok, session} ->
        {:noreply, push_navigate(socket, to: ~p"/play/#{session.id}")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not start the adventure. Please try again.")}
    end
  end

  defp show_finalize_errors(socket, errors) do
    case Keyword.get(errors, :name) do
      nil -> assign(socket, step: "stats", name_error: nil)
      message -> assign(socket, :name_error, sentence(message))
    end
  end

  defp update_draft(socket, {:ok, draft}),
    do: {:noreply, assign(socket, draft: draft, refused: nil)}

  defp update_draft(socket, {:error, {_field, message}}),
    do: {:noreply, assign(socket, :refused, sentence(message))}

  # A two-stat bonus always holds two picks: a new stat replaces the oldest one.
  defp next_picks(_picks, stat, 1), do: [stat]

  defp next_picks(picks, stat, count) do
    if stat in picks, do: picks, else: Enum.take(picks ++ [stat], -count)
  end

  defp step_open?("origin", _draft), do: true
  defp step_open?("stats", _draft), do: true
  defp step_open?("name", draft), do: stats_errors(draft) == []
  defp step_open?(_, _draft), do: false

  defp stats_errors(draft) do
    case CC.validate(draft) do
      :ok ->
        []

      {:error, errors} ->
        for {field, msg} <- errors, field in [:stats, :race_picks], do: sentence(msg)
    end
  end

  defp race_choice(options, race), do: Enum.find(options.races, &(&1.id == race)).choice

  # --- render -----------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:steps, @steps)
      |> assign(:later, @later)
      |> assign(:stats_errors, stats_errors(assigns.draft))
      |> assign(:points_left, CC.points_left(assigns.draft))

    ~H"""
    <Layouts.app flash={@flash}>
      <div id="create-character" class="paper-themed space-y-6">
        <header class="space-y-2">
          <p class="play-label text-[var(--paper-accent)]">New character · {@adventure_name}</p>
          <h1 class="font-serif text-3xl font-bold text-[var(--paper-ink)]">Create your character</h1>
          <p class="text-[var(--paper-muted)]">
            Choose who you are, spend your points and give yourself a name.
            <span class="ml-1 inline-block rounded bg-[var(--paper-ok-bg)] px-2 py-0.5 text-xs font-medium text-[var(--paper-ok-ink)]">
              Your first character is free
            </span>
          </p>
        </header>

        <nav aria-label="Creation steps" class="space-y-2">
          <ol class="flex flex-wrap gap-2">
            <li :for={{{id, label}, i} <- Enum.with_index(@steps, 1)}>
              <button
                type="button"
                id={"step-#{id}"}
                phx-click="go"
                phx-value-step={id}
                disabled={id == "name" and @stats_errors != []}
                aria-current={@step == id && "step"}
                class={[
                  "rounded-full border px-3 py-1 text-sm font-medium disabled:opacity-40",
                  if(@step == id,
                    do:
                      "border-[var(--paper-accent)] bg-[var(--paper-accent)] text-[var(--paper-on-accent)]",
                    else: "border-[var(--paper-rule)] bg-[var(--paper-panel)] text-[var(--paper-ink)]"
                  )
                ]}
              >
                {i}. {label}
              </button>
            </li>
          </ol>
          <p id="later-steps" class="text-xs text-[var(--paper-muted)]">
            Coming later: {Enum.join(@later, " · ")}
          </p>
        </nav>

        <p
          :if={@refused}
          id="refused"
          role="alert"
          class="rounded border border-[var(--paper-danger-rule)] px-3 py-2 text-sm text-[var(--paper-danger-ink)]"
        >
          {@refused}
        </p>

        <.origin_step :if={@step == "origin"} draft={@draft} options={@options} />
        <.stats_step
          :if={@step == "stats"}
          draft={@draft}
          options={@options}
          points_left={@points_left}
          errors={@stats_errors}
        />
        <.name_step :if={@step == "name"} draft={@draft} options={@options} name_error={@name_error} />
      </div>
    </Layouts.app>
    """
  end

  attr :draft, :map, required: true
  attr :options, :map, required: true

  defp origin_step(assigns) do
    ~H"""
    <section id="origin-step" class="space-y-6">
      <fieldset class="space-y-2">
        <legend class="play-label mb-2">Race</legend>
        <div role="radiogroup" aria-label="Race" class="grid gap-2 sm:grid-cols-2">
          <.choice
            :for={race <- @options.races}
            event="race"
            id={race.id}
            label={label(race.id)}
            description={race.description}
            selected={@draft.race == race.id}
          />
        </div>
      </fieldset>

      <fieldset class="space-y-2">
        <legend class="play-label mb-2">Class</legend>
        <div role="radiogroup" aria-label="Class" class="grid gap-2 sm:grid-cols-2">
          <.choice
            :for={class <- @options.classes}
            event="class"
            id={class.id}
            label={class_label(class.id)}
            description={class.description}
            selected={@draft.class == class.id}
          />
        </div>
      </fieldset>

      <.step_nav next="stats" />
    </section>
    """
  end

  attr :event, :string, required: true
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :description, :string, required: true
  attr :selected, :boolean, required: true

  defp choice(assigns) do
    ~H"""
    <button
      type="button"
      role="radio"
      aria-checked={to_string(@selected)}
      id={"#{@event}-#{@id}"}
      phx-click={@event}
      phx-value-id={@id}
      class={[
        "play-panel rounded-lg px-4 py-3 text-left transition",
        @selected && "!border-2 !border-[var(--paper-accent)] !bg-[var(--paper-margin)]"
      ]}
    >
      <span class="flex items-center justify-between gap-2 font-serif font-semibold text-[var(--paper-ink)]">
        {@label}
        <span :if={@selected} class="text-sm text-[var(--paper-accent)]" aria-hidden="true">✓</span>
      </span>
      <span class="block text-sm text-[var(--paper-muted)]">{@description}</span>
    </button>
    """
  end

  attr :draft, :map, required: true
  attr :options, :map, required: true
  attr :points_left, :integer, required: true
  attr :errors, :list, required: true

  defp stats_step(assigns) do
    pb = assigns.options.point_buy

    assigns =
      assigns
      |> assign(:min, pb["min"])
      |> assign(:max, pb["max"])
      |> assign(:budget, pb["budget"])
      |> assign(:modifiers, CC.race_modifiers(assigns.draft))
      |> assign(:final, CC.final_stats(assigns.draft))
      |> assign(:choice, race_choice(assigns.options, assigns.draft.race))
      |> assign(:stat_names, @stats)

    ~H"""
    <section id="stats-step" class="space-y-4">
      <div class="play-panel flex items-center justify-between gap-3 rounded-lg px-4 py-3">
        <div>
          <p class="play-label">Points left</p>
          <p class="text-xs text-[var(--paper-muted)]">
            {@budget} to spend, {@min}–{@max} per stat
          </p>
        </div>
        <p
          id="points-left"
          class={[
            "font-serif text-3xl font-bold",
            if(@points_left < 0,
              do: "text-[var(--paper-danger-ink)]",
              else: "text-[var(--paper-ink)]"
            )
          ]}
        >
          {@points_left}
        </p>
      </div>

      <div :if={@choice} id="race-bonus" class="play-panel space-y-2 rounded-lg px-4 py-3">
        <p class="play-label">{label(@draft.race)} bonus</p>
        <p class="text-sm text-[var(--paper-muted)]">
          +{@choice["amount"]} to {if @choice["count"] == 1,
            do: Enum.join(@choice["from"], " or "),
            else: "any #{@choice["count"]} stats"}{if @choice["count"] > 1,
            do: ". Pick another to move a bonus.",
            else: "."}
        </p>
        <div class="flex flex-wrap gap-2">
          <button
            :for={stat <- @choice["from"]}
            type="button"
            id={"pick-#{stat}"}
            phx-click="pick"
            phx-value-stat={stat}
            aria-pressed={to_string(stat in @draft.race_picks)}
            class={[
              "rounded-full border px-3 py-1 text-sm font-medium",
              if(stat in @draft.race_picks,
                do:
                  "border-[var(--paper-accent)] bg-[var(--paper-accent)] text-[var(--paper-on-accent)]",
                else: "border-[var(--paper-rule)] text-[var(--paper-ink)]"
              )
            ]}
          >
            {stat}
          </button>
        </div>
      </div>

      <div class="play-panel rounded-lg">
        <div class="grid grid-cols-[1fr_auto_3rem_3rem] items-center gap-x-3 border-b border-[var(--paper-rule)] px-4 py-2">
          <span class="play-label">Stat</span>
          <span class="play-label text-center">Points</span>
          <span class="play-label text-center">Race</span>
          <span class="play-label text-center">Total</span>
        </div>
        <div
          :for={{stat, name} <- @stat_names}
          id={"stat-#{stat}"}
          class="grid grid-cols-[1fr_auto_3rem_3rem] items-center gap-x-3 border-b border-[var(--paper-rule)] px-4 py-2 last:border-b-0"
        >
          <span class="min-w-0">
            <span class="font-semibold text-[var(--paper-ink)]">{stat}</span>
            <span class="ml-2 hidden text-sm text-[var(--paper-muted)] sm:inline">{name}</span>
          </span>
          <span class="flex items-center gap-2">
            <button
              type="button"
              id={"dec-#{stat}"}
              phx-click="stat"
              phx-value-stat={stat}
              phx-value-delta="-1"
              disabled={@draft.base_stats[stat] <= @min}
              aria-label={"Lower #{name}"}
              class="size-9 rounded border border-[var(--paper-rule)] text-lg text-[var(--paper-ink)] disabled:opacity-30"
            >
              −
            </button>
            <span class="w-6 text-center font-mono text-[var(--paper-ink)]">
              {@draft.base_stats[stat]}
            </span>
            <button
              type="button"
              id={"inc-#{stat}"}
              phx-click="stat"
              phx-value-stat={stat}
              phx-value-delta="1"
              disabled={@draft.base_stats[stat] >= @max or @points_left <= 0}
              aria-label={"Raise #{name}"}
              class="size-9 rounded border border-[var(--paper-rule)] text-lg text-[var(--paper-ink)] disabled:opacity-30"
            >
              +
            </button>
          </span>
          <span class="text-center text-sm text-[var(--paper-muted)]">
            {signed(Map.get(@modifiers, stat, 0))}
          </span>
          <span
            id={"total-#{stat}"}
            class={[
              "text-center font-serif text-lg font-semibold",
              if(@final[stat] < @min or @final[stat] > @max,
                do: "text-[var(--paper-danger-ink)]",
                else: "text-[var(--paper-ink)]"
              )
            ]}
          >
            {@final[stat]}
          </span>
        </div>
      </div>

      <ul :if={@errors != []} id="stats-errors" role="alert" class="space-y-1">
        <li :for={error <- @errors} class="text-sm text-[var(--paper-danger-ink)]">{error}</li>
      </ul>

      <.step_nav back="origin" next="name" next_disabled={@errors != []} />
    </section>
    """
  end

  attr :draft, :map, required: true
  attr :options, :map, required: true
  attr :name_error, :string, default: nil

  defp name_step(assigns) do
    class = Enum.find(assigns.options.classes, &(&1.id == assigns.draft.class))

    assigns =
      assigns
      |> assign(:final, CC.final_stats(assigns.draft))
      |> assign(:skills, class.skills)
      |> assign(:stat_names, @stats)

    ~H"""
    <section id="name-step" class="space-y-4">
      <.form
        for={%{}}
        as={:character}
        id="name-form"
        phx-change="name"
        phx-submit="begin"
        class="space-y-4"
      >
        <div class="play-panel space-y-2 rounded-lg px-4 py-3">
          <label for="character-name" class="play-label">Name</label>
          <input
            id="character-name"
            name="name"
            type="text"
            value={@draft.name}
            maxlength={@options.name_max_length + 10}
            autocomplete="off"
            placeholder="Type your character's name"
            aria-invalid={@name_error && "true"}
            aria-describedby={@name_error && "name-error"}
            class="w-full rounded border border-[var(--paper-rule)] bg-[var(--paper-bg)] px-3 py-2 text-[var(--paper-ink)] placeholder:text-[var(--paper-muted)] focus:border-[var(--paper-accent)] focus:outline-none"
          />
          <p :if={@name_error} id="name-error" class="text-sm text-[var(--paper-danger-ink)]">
            {@name_error}
          </p>
        </div>

        <div id="summary" class="play-panel space-y-3 rounded-lg px-4 py-3">
          <p class="font-serif text-lg font-semibold text-[var(--paper-ink)]">
            {if @draft.name == "", do: "Your character", else: @draft.name}
          </p>
          <p class="text-sm text-[var(--paper-muted)]">
            {label(@draft.race)} · {class_label(@draft.class)}
          </p>
          <dl class="grid grid-cols-3 gap-2 sm:grid-cols-6">
            <div
              :for={{stat, _name} <- @stat_names}
              class="rounded bg-[var(--paper-margin)] px-2 py-1 text-center"
            >
              <dt class="play-label">{stat}</dt>
              <dd class="font-serif text-lg font-semibold text-[var(--paper-ink)]">{@final[stat]}</dd>
            </div>
          </dl>
          <p :if={@skills != %{}} class="text-sm text-[var(--paper-ink)]">
            <span class="play-label">Skills</span>
            {Enum.map_join(@skills, ", ", fn {skill, level} -> "#{label(skill)} #{level}" end)}
          </p>
        </div>

        <div class="flex items-center justify-between gap-3">
          <button
            type="button"
            phx-click="go"
            phx-value-step="stats"
            class="rounded border border-[var(--paper-rule)] px-4 py-2 font-medium text-[var(--paper-ink)] hover:opacity-80"
          >
            Back
          </button>
          <button
            type="submit"
            id="begin"
            phx-disable-with="Starting…"
            class="rounded bg-[var(--paper-accent)] px-4 py-2 font-medium text-[var(--paper-on-accent)] hover:opacity-90"
          >
            Begin adventure
          </button>
        </div>
      </.form>
    </section>
    """
  end

  attr :back, :string, default: nil
  attr :next, :string, required: true
  attr :next_disabled, :boolean, default: false

  defp step_nav(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3">
      <button
        :if={@back}
        type="button"
        phx-click="go"
        phx-value-step={@back}
        class="rounded border border-[var(--paper-rule)] px-4 py-2 font-medium text-[var(--paper-ink)] hover:opacity-80"
      >
        Back
      </button>
      <span :if={!@back}></span>
      <button
        type="button"
        id={"next-#{@next}"}
        phx-click="go"
        phx-value-step={@next}
        disabled={@next_disabled}
        class="rounded bg-[var(--paper-accent)] px-4 py-2 font-medium text-[var(--paper-on-accent)] hover:opacity-90 disabled:opacity-40"
      >
        Next
      </button>
    </div>
    """
  end

  # Rule messages are lower-case fragments; on screen they start with a capital.
  defp sentence(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  defp label(id), do: id |> String.replace("_", " ") |> String.capitalize()

  defp class_label("none"), do: "No class"
  defp class_label(id), do: label(id)

  defp signed(0), do: "—"
  defp signed(n) when n > 0, do: "+#{n}"
  defp signed(n), do: "#{n}"
end
