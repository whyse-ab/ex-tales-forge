defmodule TalesForgeWeb.TeamArt do
  @moduledoc """
  Hand-drawn inline SVG illustrations for the founders' page (`/team`): the
  crew avatars, the persona tokens, the round-table hero, the founders' wax
  seal and the d20 token of the change-flow animation.

  They are placeholders for the painterly tavern-style art in the content
  brief (tales-forge-docs `docs/team-page/content.md`, "Image ideas"): simple
  flat shapes in the same warm palette, no real likenesses, nobody drawn above
  anyone else. Inline, so there is nothing to fetch and they need no public
  static route. Decorative parts are `aria-hidden`; each picture has a label.
  """

  use Phoenix.Component

  @skins %{a: "#e9bb92", b: "#c48a5f", c: "#8e5b3d", d: "#f2cdb0"}

  @doc """
  A round crew avatar: `id` is `founders`, `case`, `bobby` or `gentry`
  (anything else draws a neutral circle).
  """
  attr :id, :string, required: true
  attr :class, :string, default: "size-16"
  attr :label, :string, default: nil

  @spec avatar(map()) :: Phoenix.LiveView.Rendered.t()
  def avatar(assigns) do
    assigns = assign(assigns, :skins, @skins)

    ~H"""
    <svg
      viewBox="0 0 64 64"
      class={["team-avatar shrink-0", @class]}
      role="img"
      aria-label={@label || "#{@id} avatar"}
    >
      <circle cx="32" cy="32" r="30.5" fill="#f3dcae" stroke="#b4874a" stroke-width="2" />
      <.avatar_body id={@id} skins={@skins} />
    </svg>
    """
  end

  attr :id, :string, required: true
  attr :skins, :map, required: true

  defp avatar_body(%{id: "founders"} = assigns) do
    ~H"""
    <g aria-hidden="true">
      <path d="M6 50 Q14 36 22 50 Z" fill="#3f6e8c" />
      <path d="M22 50 Q32 34 42 50 Z" fill="#8a3f5f" />
      <path d="M42 50 Q50 36 58 50 Z" fill="#4d7a4a" />
      <circle cx="14" cy="32" r="6" fill={@skins.a} />
      <circle cx="32" cy="32" r="6" fill={@skins.c} />
      <circle cx="50" cy="32" r="6" fill={@skins.b} />
      <path d="M8 30 Q14 22 20 30" fill="#5a3a22" />
      <path d="M26 30 Q32 22 38 30" fill="#1f1a17" />
      <path d="M44 30 Q50 23 56 30" fill="#b7652b" />
      <ellipse cx="32" cy="52" rx="25" ry="7" fill="#8a5a35" />
      <circle cx="32" cy="51" r="4.5" fill="#a3182f" />
      <circle cx="32" cy="51" r="2" fill="#e4677d" />
    </g>
    """
  end

  defp avatar_body(%{id: "case"} = assigns) do
    ~H"""
    <g aria-hidden="true">
      <path
        d="M12 18 H52 M8 28 H56 M8 38 H56 M18 8 V56 M30 4 V60 M42 6 V58"
        stroke="#7fa7c9"
        stroke-width="0.8"
        opacity="0.7"
      />
      <path d="M14 58 Q32 34 50 58 Z" fill="#2f4f6f" />
      <circle cx="32" cy="27" r="9" fill={@skins.d} />
      <path d="M23 25 Q32 12 41 25 Q36 20 23 25" fill="#6b4a2b" />
      <circle cx="29" cy="27" r="1" fill="#2b211a" />
      <circle cx="35" cy="27" r="1" fill="#2b211a" />
      <path d="M29.5 31 Q32 32.5 34.5 31" stroke="#2b211a" stroke-width="1" fill="none" />
      <rect x="20" y="46" width="24" height="9" rx="1.5" fill="#efe0bd" stroke="#9c7a45" />
      <path d="M24 50 Q30 47 33 51 T42 49" stroke="#a3182f" stroke-width="1" fill="none" />
      <circle cx="50" cy="14" r="6" fill="#f7efd9" stroke="#9c7a45" />
      <path d="M50 9 L51.5 14 L50 19 L48.5 14 Z" fill="#a3182f" />
    </g>
    """
  end

  defp avatar_body(%{id: "bobby"} = assigns) do
    ~H"""
    <g aria-hidden="true">
      <path d="M14 58 Q32 34 50 58 Z" fill="#6b4630" />
      <path d="M26 44 H38 V58 H26 Z" fill="#a8763f" />
      <circle cx="32" cy="27" r="9" fill={@skins.b} />
      <path d="M23 24 Q32 14 41 24" fill="#2b211a" />
      <rect x="24.5" y="23" width="15" height="4" rx="2" fill="#4b5563" />
      <circle cx="28.5" cy="25" r="1.8" fill="#9bd3f0" />
      <circle cx="35.5" cy="25" r="1.8" fill="#9bd3f0" />
      <path d="M29 31 Q32 33 35 31" stroke="#2b211a" stroke-width="1" fill="none" />
      <path d="M6 50 H18 L16 54 H8 Z" fill="#4b5563" />
      <rect x="44" y="47" width="13" height="8" rx="1" fill="#374151" />
      <rect x="45.5" y="48.5" width="10" height="5" fill="#7dd3c0" />
      <text x="9" y="44" font-size="7" font-family="monospace" font-weight="700" fill="#e8590c">
        |&gt;
      </text>
      <circle cx="19" cy="40" r="1" fill="#f59f00" />
      <circle cx="16" cy="36" r="0.8" fill="#f59f00" />
    </g>
    """
  end

  defp avatar_body(%{id: "gentry"} = assigns) do
    ~H"""
    <g aria-hidden="true">
      <path d="M14 58 Q32 34 50 58 Z" fill="#3d5a3c" />
      <circle cx="32" cy="27" r="9" fill={@skins.a} />
      <path d="M22 23 L32 15 L42 23 Q32 19 22 23" fill="#3a2a1c" />
      <circle cx="28.5" cy="27" r="1" fill="#2b211a" />
      <path d="M28 32 Q32 35.5 37 31" stroke="#2b211a" stroke-width="1.1" fill="none" />
      <circle
        cx="37"
        cy="26"
        r="5"
        fill="#cfe9f7"
        fill-opacity="0.55"
        stroke="#8a6a2f"
        stroke-width="1.8"
      />
      <path d="M40.5 29.5 L47 36" stroke="#8a6a2f" stroke-width="2.4" stroke-linecap="round" />
      <path d="M12 52 Q16 40 24 34 Q19 44 15 52 Z" fill="#c92a2a" />
      <path d="M12 52 L18 42" stroke="#7a1d1d" stroke-width="0.8" />
    </g>
    """
  end

  defp avatar_body(assigns) do
    ~H"""
    <g aria-hidden="true">
      <circle cx="32" cy="32" r="12" fill="#b4874a" opacity="0.5" />
    </g>
    """
  end

  @doc """
  A small persona token: `hawk` (sword), `paul` (theatre mask), `lotta` (hand
  mirror), `lars` (quest map) or `ronny` (sack of gold, greyed: the
  anti-persona).
  """
  attr :id, :string, required: true
  attr :class, :string, default: "size-12"

  @spec persona_token(map()) :: Phoenix.LiveView.Rendered.t()
  def persona_token(assigns) do
    ~H"""
    <svg
      viewBox="0 0 48 48"
      class={["shrink-0", @id == "ronny" && "team-greyed", @class]}
      role="img"
      aria-label={"#{@id} token"}
    >
      <circle cx="24" cy="24" r="22.5" fill="#f3dcae" stroke="#b4874a" stroke-width="2" />
      <.token_icon id={@id} />
    </svg>
    """
  end

  attr :id, :string, required: true

  defp token_icon(%{id: "hawk"} = assigns) do
    ~H"""
    <g aria-hidden="true">
      <path d="M14 34 L32 12 L35 15 L17 37 Z" fill="#cbd5e1" stroke="#475569" />
      <path d="M13 29 L22 38" stroke="#7c4a1e" stroke-width="3" stroke-linecap="round" />
      <path d="M11 39 L15 35" stroke="#7c4a1e" stroke-width="3" stroke-linecap="round" />
    </g>
    """
  end

  defp token_icon(%{id: "paul"} = assigns) do
    ~H"""
    <g aria-hidden="true">
      <path
        d="M12 14 Q24 10 36 14 Q37 30 24 37 Q11 30 12 14 Z"
        fill="#fdf6e3"
        stroke="#7c3aed"
        stroke-width="1.5"
      />
      <path
        d="M16 20 Q19 18 21 21 M27 21 Q29 18 32 20"
        stroke="#3b2f5e"
        stroke-width="1.6"
        fill="none"
      />
      <path d="M17 27 Q24 33 31 27" stroke="#3b2f5e" stroke-width="1.6" fill="none" />
    </g>
    """
  end

  defp token_icon(%{id: "lotta"} = assigns) do
    ~H"""
    <g aria-hidden="true">
      <circle cx="24" cy="19" r="9" fill="#d6ecf5" stroke="#a16207" stroke-width="2.5" />
      <path d="M20 15 Q22 13 25 14" stroke="#ffffff" stroke-width="1.5" fill="none" />
      <path d="M24 28 V39" stroke="#a16207" stroke-width="3.5" stroke-linecap="round" />
    </g>
    """
  end

  defp token_icon(%{id: "lars"} = assigns) do
    ~H"""
    <g aria-hidden="true">
      <path
        d="M11 14 L19 12 L29 15 L37 13 V34 L29 36 L19 33 L11 35 Z"
        fill="#efe0bd"
        stroke="#9c7a45"
      />
      <path d="M19 12 V33 M29 15 V36" stroke="#9c7a45" stroke-width="0.8" />
      <path
        d="M14 30 Q20 24 24 26 T33 18"
        stroke="#a3182f"
        stroke-width="1.3"
        stroke-dasharray="2 2"
        fill="none"
      />
      <path d="M31 16 L35 20 M35 16 L31 20" stroke="#a3182f" stroke-width="1.6" />
    </g>
    """
  end

  defp token_icon(%{id: "ronny"} = assigns) do
    ~H"""
    <g aria-hidden="true">
      <path d="M17 18 Q24 22 31 18 Q38 28 34 36 Q24 40 14 36 Q10 28 17 18 Z" fill="#a8763f" />
      <path d="M18 17 Q24 13 30 17" stroke="#6b4630" stroke-width="2" fill="none" />
      <circle cx="33" cy="37" r="3.2" fill="#f2c94c" stroke="#a16207" />
      <circle cx="13" cy="37" r="2.6" fill="#f2c94c" stroke="#a16207" />
    </g>
    """
  end

  defp token_icon(assigns) do
    ~H"""
    <circle cx="24" cy="24" r="8" fill="#b4874a" opacity="0.5" aria-hidden="true" />
    """
  end

  @doc """
  The founders' wax seal with their shared crest (a shield with one dot per
  founder seat), used on the approval steps.
  """
  attr :class, :string, default: "size-12"
  attr :rest, :global

  @spec seal(map()) :: Phoenix.LiveView.Rendered.t()
  def seal(assigns) do
    ~H"""
    <svg
      viewBox="0 0 48 48"
      class={["team-seal", @class]}
      role="img"
      aria-label="The founders' wax seal"
      {@rest}
    >
      <g fill="#a3182f">
        <circle cx="24" cy="24" r="19" />
        <circle cx="24" cy="5.5" r="4" />
        <circle cx="41" cy="16" r="3.5" />
        <circle cx="39" cy="35" r="4" />
        <circle cx="22" cy="43" r="3.5" />
        <circle cx="7" cy="33" r="4" />
        <circle cx="8" cy="13" r="3.5" />
      </g>
      <circle cx="24" cy="24" r="13.5" fill="none" stroke="#7a0f22" stroke-width="2" />
      <path
        d="M17 17 H31 V25 Q31 31 24 34 Q17 31 17 25 Z"
        fill="#e4677d"
        stroke="#7a0f22"
        stroke-width="1"
      />
      <circle cx="21" cy="22" r="1.6" fill="#7a0f22" />
      <circle cx="27" cy="22" r="1.6" fill="#7a0f22" />
      <circle cx="24" cy="27.5" r="1.6" fill="#7a0f22" />
    </svg>
    """
  end

  @doc "The d20 token that rolls through the change-flow animation."
  attr :class, :string, default: "size-9"
  attr :rest, :global

  @spec d20(map()) :: Phoenix.LiveView.Rendered.t()
  def d20(assigns) do
    ~H"""
    <svg viewBox="0 0 40 40" class={@class} aria-hidden="true" {@rest}>
      <path
        d="M20 2 L36 11 V29 L20 38 L4 29 V11 Z"
        fill="#f2b544"
        stroke="#8a5a1b"
        stroke-width="1.5"
      />
      <path
        d="M20 2 L20 9 M36 11 L31 27 M4 11 L9 27 M20 38 L20 31 M20 9 L31 27 L9 27 Z M4 29 L9 27 M36 29 L31 27"
        stroke="#8a5a1b"
        stroke-width="1"
        fill="none"
      />
      <text x="20" y="23.5" font-size="8" font-weight="700" text-anchor="middle" fill="#5c3a0e">
        20
      </text>
    </svg>
    """
  end

  @doc "A quill (the GM node of the architecture diagram)."
  attr :class, :string, default: "size-5"

  @spec quill(map()) :: Phoenix.LiveView.Rendered.t()
  def quill(assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      class={@class}
      aria-hidden="true"
      fill="none"
      stroke="currentColor"
      stroke-width="1.6"
    >
      <path d="M20 3 C12 4 7 10 5 19 L6 20 C9 13 13 9 20 3 Z" fill="currentColor" fill-opacity="0.2" />
      <path d="M5 19 L3 21 M9 13 L13 14" stroke-linecap="round" />
    </svg>
    """
  end

  @doc """
  Hero art: one round table, seen at an angle, with a map of Tin Valley on it.
  Founders (generic adventurers) and the three bots sit around it at the same
  height, with two empty chairs left open as an invitation. The candle flame
  flickers unless reduced motion is on.
  """
  attr :class, :string, default: "w-full h-auto"

  @spec hero(map()) :: Phoenix.LiveView.Rendered.t()
  def hero(assigns) do
    assigns =
      assign(assigns,
        back: [
          {70, "#3f6e8c", @skins.a, "#5a3a22", nil},
          {150, "#2f4f6f", @skins.d, "#6b4a2b", :compass},
          {240, "#8a3f5f", @skins.c, "#1f1a17", nil},
          {330, "#6b4630", @skins.b, "#2b211a", :goggles},
          {410, "#4d7a4a", @skins.b, "#b7652b", nil}
        ],
        front: [{110, "#3d5a3c", @skins.a, "#3a2a1c", :lens}]
      )

    ~H"""
    <svg
      viewBox="0 0 480 270"
      class={["team-hero-art", @class]}
      role="img"
      aria-label="Founders and three bots around one round table, leaning over a map of Tin Valley, with two empty chairs left open"
    >
      <g aria-hidden="true">
        <ellipse cx="240" cy="250" rx="230" ry="16" fill="#000" opacity="0.08" />
        <%= for {x, cloak, skin, hair, prop} <- @back do %>
          <.seat_figure x={x} y={92} cloak={cloak} skin={skin} hair={hair} prop={prop} />
        <% end %>
        <ellipse cx="240" cy="160" rx="210" ry="66" fill="#7b4f2e" />
        <ellipse cx="240" cy="154" rx="204" ry="61" fill="#9a6a41" />
        <g transform="translate(150 118) rotate(-4)">
          <rect width="180" height="72" rx="4" fill="#efe0bd" stroke="#9c7a45" />
          <path d="M8 58 L26 34 L40 52 L56 26 L74 54" fill="#c8b083" stroke="#8c6d3e" />
          <path d="M84 6 Q96 30 88 44 T104 70" stroke="#5b8db8" stroke-width="3" fill="none" />
          <rect x="120" y="22" width="14" height="10" fill="#a3182f" opacity="0.85" />
          <path d="M140 46 L150 56 M150 46 L140 56" stroke="#a3182f" stroke-width="2.5" />
          <path d="M60 64 Q100 52 136 36" stroke="#6b4a2b" stroke-dasharray="3 3" fill="none" />
        </g>
        <rect x="336" y="126" width="9" height="20" rx="2" fill="#f7efd9" />
        <path
          class="team-flame"
          d="M340.5 108 Q347 118 340.5 126 Q334 118 340.5 108 Z"
          fill="#f59f00"
        />
        <circle cx="134" cy="170" r="10" fill="#a3182f" />
        <circle cx="134" cy="170" r="4" fill="#e4677d" />
        <%= for {x, cloak, skin, hair, prop} <- @front do %>
          <.back_figure x={x} cloak={cloak} skin={skin} hair={hair} prop={prop} />
        <% end %>
        <.empty_chair x={250} />
        <.empty_chair x={370} />
      </g>
    </svg>
    """
  end

  attr :x, :integer, required: true
  attr :y, :integer, required: true
  attr :cloak, :string, required: true
  attr :skin, :string, required: true
  attr :hair, :string, required: true
  attr :prop, :atom, default: nil

  defp seat_figure(assigns) do
    ~H"""
    <g transform={"translate(#{@x} #{@y})"}>
      <path d="M-34 70 Q0 6 34 70 Z" fill={@cloak} />
      <circle cx="0" cy="0" r="18" fill={@skin} />
      <path d="M-18 -2 Q0 -28 18 -2 Q8 -12 -18 -2" fill={@hair} />
      <circle cx="-6" cy="2" r="1.8" fill="#2b211a" />
      <circle cx="6" cy="2" r="1.8" fill="#2b211a" />
      <path d="M-5 9 Q0 12 5 9" stroke="#2b211a" stroke-width="1.6" fill="none" />
      <circle :if={@prop == :compass} cx="26" cy="-14" r="8" fill="#f7efd9" stroke="#9c7a45" />
      <path :if={@prop == :compass} d="M26 -21 L28 -14 L26 -7 L24 -14 Z" fill="#a3182f" />
      <rect :if={@prop == :goggles} x="-12" y="-6" width="24" height="7" rx="3.5" fill="#4b5563" />
      <circle :if={@prop == :goggles} cx="-6" cy="-2.5" r="2.6" fill="#9bd3f0" />
      <circle :if={@prop == :goggles} cx="6" cy="-2.5" r="2.6" fill="#9bd3f0" />
    </g>
    """
  end

  attr :x, :integer, required: true
  attr :cloak, :string, required: true
  attr :skin, :string, required: true
  attr :hair, :string, required: true
  attr :prop, :atom, default: nil

  # Seen from behind, on the near side of the table.
  defp back_figure(assigns) do
    ~H"""
    <g transform={"translate(#{@x} 214)"}>
      <path d="M-40 56 Q0 -6 40 56 Z" fill={@cloak} />
      <circle cx="0" cy="0" r="19" fill={@hair} />
      <circle
        :if={@prop == :lens}
        cx="30"
        cy="-18"
        r="10"
        fill="#cfe9f7"
        fill-opacity="0.6"
        stroke="#8a6a2f"
        stroke-width="3"
      />
      <path
        :if={@prop == :lens}
        d="M23 -11 L14 -2"
        stroke="#8a6a2f"
        stroke-width="4"
        stroke-linecap="round"
      />
    </g>
    """
  end

  attr :x, :integer, required: true

  defp empty_chair(assigns) do
    ~H"""
    <g transform={"translate(#{@x} 214)"}>
      <rect x="-24" y="-14" width="48" height="40" rx="10" fill="#6b4630" />
      <rect x="-17" y="-8" width="34" height="28" rx="6" fill="#8a5a35" />
      <rect x="-26" y="26" width="52" height="8" rx="3" fill="#5a3a22" />
    </g>
    """
  end
end
