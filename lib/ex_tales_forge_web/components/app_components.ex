defmodule TalesForgeWeb.AppComponents do
  @moduledoc """
  Components that show which app you are on and link across the two apps
  (admin split, tales-forge-docs decisions.md 2026-10-10):

  - `env_badge/1`: a pill with this app's role (PRODUCTION, PLAYTEST or
    LOCAL), its app name and the short commit it runs. Every admin page and
    the /team header show it.
  - `lives_on/1`: "<what> lives on production ↗", a link to a one-home page
    (`TalesForge.AppRole` area) on the app that owns it.
  - `other_app_link/1`: "Same page on playtest ↗", for pages that exist on
    both apps with different data (sessions, costs, telemetry).

  The role comes from `TalesForge.AppRole.role/0`; tests can pass `role`.
  """

  use Phoenix.Component

  alias TalesForge.AppRole
  alias TalesForge.Playtest.RunMeta

  @doc """
  The environment badge. `role` defaults to this app's role; `sha` to the
  commit it runs (`GIT_SHA`), shown as 7 characters when known.
  """
  attr :id, :string, default: "env-badge"
  attr :role, :atom, default: nil
  attr :sha, :string, default: nil
  attr :class, :string, default: nil

  @spec env_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def env_badge(assigns) do
    role = assigns.role || AppRole.role()
    sha = assigns.sha || RunMeta.git_sha()
    short = if is_binary(sha), do: String.slice(sha, 0, 7)

    assigns =
      assign(assigns,
        role: role,
        short: short,
        name: role_name(role),
        app: AppRole.app_name()
      )

    ~H"""
    <span
      id={@id}
      data-role={@role}
      title={"You are on #{String.downcase(@name)} (#{@app}#{@short && ", commit " <> @short})"}
      class={[
        "inline-flex max-w-full items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs font-bold tracking-wide",
        role_class(@role),
        @class
      ]}
    >
      <span class="size-2 shrink-0 rounded-full bg-current" aria-hidden="true"></span>
      <span>{@name}</span>
      <span :if={@short} class="font-mono font-normal opacity-80">{@short}</span>
    </span>
    """
  end

  @doc """
  A link to a page that lives on one app only. Shows nothing when that page
  lives here. Example: "The idea board lives on production ↗".
  """
  attr :id, :string, default: nil
  attr :area, :atom, required: true
  attr :path, :string, required: true
  attr :what, :string, required: true
  attr :role, :atom, default: nil

  @spec lives_on(map()) :: Phoenix.LiveView.Rendered.t()
  def lives_on(assigns) do
    role = assigns.role || AppRole.role()

    assigns =
      assign(assigns,
        here?: AppRole.here?(assigns.area, role),
        href: AppRole.link(assigns.area, assigns.path, role),
        home: AppRole.home_label(assigns.area)
      )

    ~H"""
    <a
      :if={not @here?}
      id={@id}
      href={@href}
      data-cross-app
      class="inline-flex min-h-11 items-center gap-1 font-semibold text-[var(--paper-accent)] underline"
    >
      {@what} lives on {@home} ↗
    </a>
    """
  end

  @doc """
  "Same page on <other app> ↗" for a page that both apps serve with their own
  data. `path` is the page's path (with its query, if any). Shows nothing
  locally, where there is no other app.
  """
  attr :id, :string, default: "other-app-link"
  attr :path, :string, required: true
  attr :role, :atom, default: nil

  @spec other_app_link(map()) :: Phoenix.LiveView.Rendered.t()
  def other_app_link(assigns) do
    role = assigns.role || AppRole.role()
    assigns = assign(assigns, :other, other(role))

    ~H"""
    <a
      :if={@other}
      id={@id}
      href={other_url(@other, @path)}
      data-cross-app
      class="inline-flex min-h-11 items-center gap-1 text-sm font-semibold text-[var(--paper-accent)] underline"
    >
      Same page on {@other} ↗
    </a>
    """
  end

  @doc """
  The full URL of `path` on the other app, or nil locally.

      iex> TalesForgeWeb.AppComponents.other_app_url("/admin/operate/costs", :production)
      "https://tales-forge-playtest.fly.dev/admin/operate/costs"
      iex> TalesForgeWeb.AppComponents.other_app_url("/admin/play/sessions", :playtest)
      "https://tales-forge.fly.dev/admin/play/sessions"
      iex> TalesForgeWeb.AppComponents.other_app_url("/admin", :local)
      nil
  """
  @spec other_app_url(String.t(), AppRole.role()) :: String.t() | nil
  def other_app_url(path, role \\ AppRole.role()) do
    case other(role) do
      nil -> nil
      app -> other_url(app, path)
    end
  end

  @doc """
  The display name of a role.

      iex> TalesForgeWeb.AppComponents.role_name(:playtest)
      "PLAYTEST"
  """
  @spec role_name(AppRole.role()) :: String.t()
  def role_name(:production), do: "PRODUCTION"
  def role_name(:playtest), do: "PLAYTEST"
  def role_name(_local), do: "LOCAL"

  defp role_class(:production), do: "border-red-800 bg-red-700 text-white"
  defp role_class(:playtest), do: "border-amber-700 bg-amber-300 text-amber-950"
  defp role_class(_local), do: "border-slate-500 bg-slate-200 text-slate-900"

  defp other(:production), do: "playtest"
  defp other(:playtest), do: "production"
  defp other(_local), do: nil

  defp other_url(app, path) do
    base = app |> String.to_existing_atom() |> AppRole.base_url() |> String.trim_trailing("/")
    base <> path
  end
end
