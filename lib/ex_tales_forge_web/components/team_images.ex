defmodule TalesForgeWeb.TeamImages do
  @moduledoc """
  The image parts of the team chat (`TalesForgeWeb.TeamChatLive`) and the idea
  board cards (`TalesForgeWeb.TeamIdeaBoard`). The images are in
  `TalesForge.Images`.

  - `thumbnails/1`: small images; a click opens the full image in a new tab.
  - `picker/1`: the "Add image" file button, the "Capture screen" button and
    the previews of the chosen files. It goes inside a form with a LiveView
    upload. The `ImageInput` hook (`assets/js/team_hooks.js`) adds pasted
    images and the captured still to the upload. The form is the drop target.
  - "Capture screen" uses the browser's screen sharing (`getDisplayMedia`) to
    take one still of a tab, window or screen. The hook shows the button only
    on desktop browsers that can capture. Phones get the file button only.

  `allow/2` registers an upload with the image limits of `TalesForge.Images`.
  `read_all/2` reads the bytes of the finished uploads.
  """

  use Phoenix.Component

  import TalesForgeWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView
  alias TalesForge.Images

  @max_entries 4

  @doc "Registers the image upload `name` on `socket` (PNG, JPEG, WebP, up to #{@max_entries} files of 5 MB)."
  @spec allow(LiveView.Socket.t(), atom()) :: LiveView.Socket.t()
  def allow(socket, name) do
    if Map.has_key?(socket.assigns[:uploads] || %{}, name) do
      socket
    else
      LiveView.allow_upload(socket, name,
        accept: Images.extensions(),
        max_entries: @max_entries,
        max_file_size: Images.max_bytes()
      )
    end
  end

  @doc "Reads the bytes of every finished upload `name`, in order."
  @spec read_all(LiveView.Socket.t(), atom()) :: [binary()]
  def read_all(socket, name) do
    LiveView.consume_uploaded_entries(socket, name, fn %{path: path}, _entry ->
      {:ok, File.read!(path)}
    end)
  end

  @doc "A readable text for an upload error."
  @spec error_text(atom() | String.t()) :: String.t()
  def error_text(:too_large), do: "Add an image of 5 MB or less."
  def error_text(:not_accepted), do: "Add a PNG, JPEG or WebP image."
  def error_text(:too_many_files), do: "Add #{@max_entries} images or fewer at a time."
  def error_text(other), do: "The upload stopped (#{other})."

  attr :images, :list, required: true
  attr :id, :string, required: true
  attr :class, :string, default: nil

  @doc "The thumbnails of `images`. Each one opens the full image in a new tab."
  @spec thumbnails(map()) :: Phoenix.LiveView.Rendered.t()
  def thumbnails(assigns) do
    ~H"""
    <ul :if={@images != []} id={@id} class={["flex flex-wrap gap-2", @class]} aria-label="Images">
      <li :for={i <- @images} id={"#{@id}-#{i.id}"} class="max-w-full">
        <a
          href={Images.path(i)}
          target="_blank"
          rel="noopener"
          class="block overflow-hidden rounded border border-[var(--paper-rule)] focus-visible:outline-2 focus-visible:outline-[var(--paper-accent)]"
          title="Open the full image"
        >
          <img
            src={Images.path(i)}
            alt={i.note || "Image"}
            loading="lazy"
            class="max-h-40 max-w-full object-contain"
          />
          <span class="sr-only">(opens the full image in a new tab)</span>
        </a>
        <p :if={i.note} class="mt-0.5 max-w-60 text-xs text-[var(--paper-muted)]">{i.note}</p>
      </li>
    </ul>
    """
  end

  attr :upload, :any, required: true
  attr :id, :string, required: true
  attr :target, :any, default: nil
  attr :cancel_event, :string, default: "cancel_image"

  @doc """
  The file button, the "Capture screen" button and the previews of the chosen
  files, for the form of the LiveView upload `upload`.
  """
  @spec picker(map()) :: Phoenix.LiveView.Rendered.t()
  def picker(assigns) do
    ~H"""
    <div id={@id} class="grid gap-1">
      <div class="flex flex-wrap items-center gap-2">
        <label
          for={@upload.ref}
          class="inline-flex min-h-11 cursor-pointer items-center gap-1 rounded-full border border-[var(--paper-rule)] px-3 text-sm hover:bg-[var(--paper-bg)] focus-within:outline-2 focus-within:outline-[var(--paper-accent)]"
        >
          <.icon name="hero-photo" class="size-5" />
          <span>Add image</span>
          <.live_file_input upload={@upload} class="sr-only" />
        </label>
        <span id={"#{@id}-capture-slot"} phx-update="ignore" class="contents">
          <button
            id={"#{@id}-capture"}
            type="button"
            data-capture
            hidden
            class="inline-flex min-h-11 items-center gap-1 rounded-full border border-[var(--paper-rule)] px-3 text-sm hover:bg-[var(--paper-bg)]"
          >
            <.icon name="hero-computer-desktop" class="size-5" />
            <span>Capture screen</span>
          </button>
        </span>
      </div>
      <p :for={err <- upload_errors(@upload)} class="text-sm text-red-700" role="alert">
        {error_text(err)}
      </p>
      <ul :if={@upload.entries != []} class="flex flex-wrap gap-2" aria-label="Images to send">
        <li :for={entry <- @upload.entries} id={"#{@id}-entry-#{entry.ref}"} class="relative">
          <.live_img_preview
            entry={entry}
            class="h-20 max-w-40 rounded border border-[var(--paper-rule)] object-contain"
            alt={entry.client_name}
          />
          <button
            type="button"
            phx-click={@cancel_event}
            phx-value-ref={entry.ref}
            phx-target={@target}
            aria-label={"Remove #{entry.client_name}"}
            class="absolute -right-2 -top-2 grid size-7 place-items-center rounded-full border border-[var(--paper-rule)] bg-[var(--paper-panel)]"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
          <p
            :for={err <- upload_errors(@upload, entry)}
            class="text-xs text-red-700"
            role="alert"
          >
            {error_text(err)}
          </p>
        </li>
      </ul>
    </div>
    """
  end
end
