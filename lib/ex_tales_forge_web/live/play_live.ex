defmodule TalesForgeWeb.PlayLive do
  @moduledoc """
  The play page for one game session: shows the scene and turns, takes the player's action and follows turn progress over PubSub.
  """

  use TalesForgeWeb, :live_view

  import TalesForgeWeb.PlayComponents

  alias TalesForge.GameSessions
  alias TalesForge.PubSub.GameSession, as: SessionPubSub
  alias TalesForge.Repo

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      SessionPubSub.subscribe(id)
    end

    session =
      id
      |> GameSessions.get_session!()
      |> Repo.preload([:turns, :scenes])

    :ok = GameSessions.ensure_agent_started(session)
    {:ok, _} = GameSessions.ensure_scene(session)

    status = GameSessions.scene_status(id)
    entries = GameSessions.transcript(session)

    {:ok,
     socket
     |> assign(:page_title, session.name)
     |> assign(:session, session)
     |> assign(:thinking, false)
     |> assign(:scene_loading, status.needs_scene)
     |> assign(:scene_image_url, current_scene_image(session))
     |> assign(:clarification, GameSessions.pending_clarification(session.world_state))
     |> assign(:llm_source, "mock")
     |> stream(:entries, entries, reset: true)}
  end

  @impl true
  def handle_event("send_message", %{"message" => message}, socket) do
    submit_action(socket, message, [])
  end

  # A picked option plays the player's words from when the question was asked
  # (stored with the pending clarification), not whatever is in the input box:
  # the form has no phx-change, so the server never sees the box anyway.
  def handle_event("pick_clarification", %{"option_id" => option_id}, socket) do
    case socket.assigns.clarification do
      %{"clarification_id" => clarification_id} ->
        submit_action(socket, "", clarification_id: clarification_id, option_id: option_id)

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:scene_processing, _}, socket) do
    {:noreply, assign(socket, :scene_loading, true)}
  end

  def handle_info({:scene_completed, payload}, socket) do
    session =
      socket.assigns.session
      |> Map.put(:world_state, payload.world_state)
      |> refresh_scenes()

    {:noreply,
     socket
     |> assign(:scene_loading, false)
     |> assign(:session, session)
     |> assign(:llm_source, payload.llm_source)
     |> assign(:scene_image_url, payload.image_url)
     |> append_entries(payload.entries)}
  end

  def handle_info({:scene_failed, {:spend_cap, kind}}, socket) do
    {:noreply,
     socket
     |> assign(:scene_loading, false)
     |> put_flash(:info, spend_cap_message(kind))}
  end

  def handle_info({:scene_failed, reason}, socket) do
    {:noreply,
     socket
     |> assign(:scene_loading, false)
     |> put_flash(:error, "Scene failed: #{reason}")}
  end

  def handle_info({:turn_processing, _}, socket) do
    {:noreply, assign(socket, :thinking, true)}
  end

  def handle_info({:clarification_needed, clarification}, socket) do
    {:noreply,
     socket
     |> assign(:thinking, false)
     |> assign(:clarification, clarification)}
  end

  def handle_info({:turn_completed, payload}, socket) do
    session =
      socket.assigns.session
      |> Map.put(:world_state, payload.world_state)
      |> Map.put(:status, Map.get(payload, :session_status, socket.assigns.session.status))

    socket =
      socket
      |> assign(:thinking, false)
      |> assign(:clarification, nil)
      |> assign(:session, session)
      |> assign(:llm_source, payload.llm_source)
      |> append_entries(payload.entries)
      |> maybe_start_scene_after_travel(payload, session)

    {:noreply, socket}
  end

  def handle_info({:turn_failed, {:spend_cap, kind}}, socket) do
    {:noreply,
     socket
     |> assign(:thinking, false)
     |> put_flash(:info, spend_cap_message(kind))}
  end

  def handle_info({:turn_failed, reason}, socket) do
    {:noreply,
     socket
     |> assign(:thinking, false)
     |> put_flash(:error, "Turn failed: #{reason}")}
  end

  def handle_info({:npc_initiative, payload}, socket) do
    entry = %{
      id: "npc-initiative-#{payload.npc_id}-#{payload.world_tick}",
      role: "npc",
      npc_name: payload.npc_name,
      text: payload.text
    }

    {:noreply, append_entries(socket, [entry])}
  end

  @impl true
  def render(assigns) do
    world = assigns.session.world_state || %{}
    character = Map.get(world, "character", %{})

    assigns =
      assigns
      |> assign(:location_name, Map.get(world, "location_name", "Unknown"))
      |> assign(:world_clock, Map.get(world, "world_clock", "—"))
      |> assign(:character, character)
      |> assign(:present_npcs, present_npcs(world))
      |> assign(:quick_stats, quick_stats(character))
      |> assign(
        :input_disabled,
        assigns.thinking or assigns.scene_loading or session_dead?(assigns.session)
      )

    ~H"""
    <Layouts.play flash={@flash}>
      <.play_header
        session_id={@session.id}
        session_name={@session.name}
        world_clock={@world_clock}
        location_name={@location_name}
        quick_stats={@quick_stats}
      />

      <div class="flex min-h-0 flex-1 flex-col gap-3 overflow-hidden px-3 py-3 sm:px-4 lg:flex-row">
        <div class="flex min-h-0 min-w-0 flex-1 flex-col lg:min-h-0">
          <.narrative_panel
            streams={@streams}
            scene_loading={@scene_loading}
            thinking={@thinking}
            clarification={@clarification}
            input_disabled={@input_disabled}
            session_status={@session.status}
          />
        </div>
        <.visual_panel
          location_name={@location_name}
          scene_image_url={@scene_image_url}
          present_npcs={@present_npcs}
        />
      </div>

      <div class="shrink-0 px-3 pb-3 sm:px-4">
        <.state_panel character={@character} />
      </div>
    </Layouts.play>
    """
  end

  defp session_dead?(%{status: "dead"}), do: true

  defp session_dead?(session) do
    get_in(session.world_state || %{}, ["character", "vitality"]) == "dead"
  end

  defp maybe_start_scene_after_travel(socket, %{needs_scene: true}, session) do
    {:ok, _} = GameSessions.ensure_scene(session.id)
    assign(socket, :scene_loading, true)
  end

  defp maybe_start_scene_after_travel(socket, _payload, _session), do: socket

  defp spend_cap_message(:session),
    do:
      "The Game Master lays down the dice: this session has used its AI budget, so the story pauses here. Your progress is saved."

  defp spend_cap_message(:day),
    do:
      "The Game Master is resting until tomorrow: today's AI budget is used up. Your progress is saved; come back after midnight (Swedish time)."

  defp submit_action(socket, message, opts) do
    session_id = socket.assigns.session.id
    socket = assign(socket, :thinking, true)

    case GameSessions.submit_message(session_id, message, opts) do
      {:ok, %{status: :processing}} ->
        {:noreply, socket}

      {:ok, %{status: :clarification}} ->
        {:noreply, assign(socket, :thinking, false)}

      {:error, :empty_message} ->
        {:noreply,
         socket |> assign(:thinking, false) |> put_flash(:error, "Say something first.")}

      {:error, :clarification_expired} ->
        {:noreply,
         socket
         |> assign(:thinking, false)
         |> assign(:clarification, nil)
         |> put_flash(:error, "That question has passed. Say what you do.")}

      {:error, :needs_scene} ->
        {:noreply,
         socket
         |> assign(:thinking, false)
         |> put_flash(:error, "Wait for the GM to describe the scene before you act.")}

      {:error, :dead} ->
        {:noreply,
         socket
         |> assign(:thinking, false)
         |> put_flash(:error, "You are dead.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:thinking, false)
         |> put_flash(:error, "Could not process that action.")}
    end
  end

  defp current_scene_image(%{world_state: world_state, scenes: scenes}) do
    location_id = Map.get(world_state || %{}, "location_id")

    scenes
    |> Enum.find(&(&1.location_id == location_id))
    |> case do
      %{image_url: url} when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  defp refresh_scenes(%{id: id} = session) do
    scenes =
      id
      |> GameSessions.get_session!()
      |> Repo.preload(:scenes)
      |> Map.get(:scenes)

    Map.put(session, :scenes, scenes)
  end

  defp append_entries(socket, entries) do
    Enum.reduce(entries, socket, fn entry, sock ->
      stream_insert(sock, :entries, entry)
    end)
  end
end
