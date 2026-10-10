defmodule TalesForgeWeb.AdminLive.DecisionLive.Show do
  @moduledoc """
  Admin: one founder decision (from the decision queue), rendered from Markdown.
  Read-only once the open items are imported into the idea board on `/team`
  (`Collab.read_only?/0`): no interest, comments or recording.
  """

  use TalesForgeWeb, :live_view

  import TalesForgeWeb.AdminComponents

  alias TalesForge.Collab

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    decision = Collab.get_decision_by_slug!(slug)

    if connected?(socket) do
      Collab.subscribe()
      Collab.subscribe_decision(slug)
    end

    {:ok,
     socket
     |> assign(:page_title, decision.title)
     |> assign(:decision, decision)
     |> assign(:read_only, Collab.read_only?())
     |> assign(:comment_body, "")
     |> assign(:outcome_decision, decision.decision || "")
     |> assign(:outcome_rationale, decision.rationale || "")
     |> assign(:body_html, body_html(decision))}
  end

  @impl true
  def handle_info({:comment_added, comment}, socket) do
    decision = socket.assigns.decision
    comments = decision.comments ++ [comment]
    {:noreply, assign(socket, :decision, %{decision | comments: comments})}
  end

  def handle_info({:decision_updated, slug}, socket) do
    if slug == socket.assigns.decision.slug do
      decision = Collab.get_decision_by_slug!(slug)

      {:noreply,
       socket
       |> assign(:decision, decision)
       |> assign(:body_html, body_html(decision))
       |> assign(:outcome_decision, decision.decision || "")
       |> assign(:outcome_rationale, decision.rationale || "")}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:decisions_updated}, socket) do
    decision = Collab.get_decision_by_slug!(socket.assigns.decision.slug)
    {:noreply, assign(socket, :decision, decision)}
  end

  # Relative links in the body (`../docs/why-elixir.md`) open the doc viewer.
  defp body_html(decision),
    do: Collab.render_body(decision.body, Collab.decision_repo_path(decision))

  @impl true
  def handle_event(event, _params, %{assigns: %{read_only: true}} = socket)
      when event in ["toggle_interested", "add_comment", "record_decision"] do
    {:noreply,
     put_flash(socket, :error, TalesForgeWeb.AdminLive.DecisionLive.Index.read_only_message())}
  end

  def handle_event("toggle_interested", _params, socket) do
    _ = Collab.toggle_interested(socket.assigns.decision, socket.assigns.admin_email)
    decision = Collab.get_decision_by_slug!(socket.assigns.decision.slug)
    {:noreply, assign(socket, :decision, decision)}
  end

  def handle_event("add_comment", %{"body" => body}, socket) do
    body = String.trim(body || "")

    if body == "" do
      {:noreply, put_flash(socket, :error, "Comment cannot be empty.")}
    else
      case Collab.add_comment(socket.assigns.decision, socket.assigns.admin_email, body) do
        {:ok, _} ->
          decision = Collab.get_decision_by_slug!(socket.assigns.decision.slug)
          {:noreply, assign(socket, decision: decision, comment_body: "")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not save comment.")}
      end
    end
  end

  def handle_event("record_decision", params, socket) do
    attrs = %{
      "decision" => Map.get(params, "decision", ""),
      "rationale" => Map.get(params, "rationale", "")
    }

    case Collab.record_decision(
           socket.assigns.decision,
           attrs,
           socket.assigns.admin_email
         ) do
      {:ok, updated} ->
        decision = Collab.get_decision_by_slug!(updated.slug)

        {:noreply,
         socket
         |> assign(:decision, decision)
         |> put_flash(:info, "Decision recorded. (Markdown export back to Git is a TODO.)")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not record decision.")}
    end
  end

  @impl true
  def render(assigns) do
    interested? = Collab.interested?(assigns.decision, assigns.admin_email)
    assigns = assign(assigns, :interested?, interested?)

    ~H"""
    <Layouts.admin socket={@socket} flash={@flash} active="decisions">
      <div class="space-y-1">
        <.link navigate={~p"/admin/founders/decisions"} class="text-sm text-[var(--paper-accent)]">
          ← Decision queue
        </.link>
        <div class="flex flex-wrap items-center gap-3">
          <h2 class="font-serif text-2xl font-bold text-[var(--paper-ink)]">{@decision.title}</h2>
          <span class="rounded-full bg-[var(--paper-panel)] px-2 py-0.5 text-xs border border-[var(--paper-rule)]">
            {@decision.status}
          </span>
          <span class="text-xs text-[var(--paper-muted)]">rank {@decision.rank}</span>
        </div>
        <p class="text-xs text-[var(--paper-muted)]">{@decision.slug}</p>
      </div>

      <.section_card title="Context">
        <article
          id={"decision-body-#{@decision.id}-#{:erlang.phash2(@decision.body)}"}
          phx-hook="Mermaid"
          phx-update="ignore"
          class="prose prose-sm max-w-none text-[var(--paper-ink)]"
        >
          {@body_html}
        </article>
      </.section_card>

      <.section_card title="Options">
        <%= if @decision.options == [] do %>
          <p class="text-sm text-[var(--paper-muted)]">No options listed yet.</p>
        <% else %>
          <ul class="list-disc pl-5 space-y-1 text-sm">
            <li :for={opt <- @decision.options}>{opt}</li>
          </ul>
        <% end %>
      </.section_card>

      <.section_card title="Interested">
        <p class="text-sm text-[var(--paper-muted)] mb-2">
          Self-select only — never assign owners or tasks to people.
        </p>
        <button
          :if={!@read_only}
          type="button"
          phx-click="toggle_interested"
          class="rounded bg-[var(--paper-accent)] px-3 py-1.5 text-sm text-[var(--paper-on-accent)]"
        >
          {if @interested?, do: "I'm no longer interested", else: "I'm interested"}
        </button>
        <ul class="mt-3 text-sm space-y-1">
          <li :for={i <- @decision.interests} class="text-[var(--paper-ink)]">{i.email}</li>
        </ul>
      </.section_card>

      <.section_card title="Comments">
        <ul id="comments" class="space-y-3 mb-4">
          <li
            :for={c <- @decision.comments}
            class="rounded border border-[var(--paper-rule)] bg-[var(--paper-bg)] p-3"
          >
            <p class="text-xs text-[var(--paper-muted)]">
              {c.author_email} · {Calendar.strftime(c.inserted_at, "%Y-%m-%d %H:%M UTC")}
            </p>
            <p class="mt-1 text-sm whitespace-pre-wrap">{c.body}</p>
          </li>
        </ul>

        <form :if={!@read_only} phx-submit="add_comment" class="space-y-2">
          <textarea
            name="body"
            rows="3"
            class="w-full rounded border border-[var(--paper-rule)] bg-[var(--paper-bg)] p-2 text-sm"
            placeholder="Add a comment…"
          >{@comment_body}</textarea>
          <button
            type="submit"
            class="rounded bg-[var(--paper-accent)] px-3 py-1.5 text-sm text-[var(--paper-on-accent)]"
          >
            Comment
          </button>
        </form>
      </.section_card>

      <.section_card title="Record decision">
        <%= if @decision.status == "decided" do %>
          <dl class="text-sm space-y-2">
            <div>
              <dt class="play-label text-[var(--paper-muted)]">Decision</dt>
              <dd>{@decision.decision}</dd>
            </div>
            <div>
              <dt class="play-label text-[var(--paper-muted)]">Rationale</dt>
              <dd class="whitespace-pre-wrap">{@decision.rationale}</dd>
            </div>
            <div>
              <dt class="play-label text-[var(--paper-muted)]">Decided at</dt>
              <dd>{@decision.decided_at && Calendar.strftime(@decision.decided_at, "%Y-%m-%d")}</dd>
            </div>
          </dl>
        <% end %>
        <p
          :if={@read_only and @decision.status != "decided"}
          class="text-sm text-[var(--paper-muted)]"
        >
          Read-only: this item continues on the founders' idea board on /team.
        </p>
        <%= if @decision.status != "decided" and !@read_only do %>
          <p class="text-sm text-[var(--paper-muted)] mb-2">
            Humans only. Agents must never mark a decision decided.
          </p>
          <form phx-submit="record_decision" class="space-y-3">
            <label class="block space-y-1">
              <span class="play-label text-[var(--paper-muted)]">Chosen option / decision</span>
              <input
                type="text"
                name="decision"
                required
                value={@outcome_decision}
                class="w-full rounded border border-[var(--paper-rule)] bg-[var(--paper-bg)] px-3 py-2 text-sm"
              />
            </label>
            <label class="block space-y-1">
              <span class="play-label text-[var(--paper-muted)]">Rationale</span>
              <textarea
                name="rationale"
                rows="4"
                required
                class="w-full rounded border border-[var(--paper-rule)] bg-[var(--paper-bg)] p-2 text-sm"
              >{@outcome_rationale}</textarea>
            </label>
            <button
              type="submit"
              class="rounded bg-[var(--paper-ok-solid)] px-3 py-1.5 text-sm text-white"
            >
              Record as decided
            </button>
          </form>
        <% end %>
      </.section_card>
    </Layouts.admin>
    """
  end
end
