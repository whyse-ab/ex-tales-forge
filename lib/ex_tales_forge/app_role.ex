defmodule TalesForge.AppRole do
  @moduledoc """
  Which app this is (production, playtest or local) and which app owns what.

  Each thing lives in one place: founder surveys live only on production and
  playtest runs only on playtest. The other app redirects those admin pages
  (`TalesForgeWeb.Plugs.HomeApp`), links to
  them from the admin nav, and refuses to store that data
  (`TalesForge.Surveys.save_section/4`, `TalesForge.Playtest.Runner.enabled?/0`).

  The role comes from the app name (`FLY_APP_NAME`, set by Fly; config
  `:app_name`, read through `TalesForge.Costs.app_name/0`): a name containing
  "playtest" is playtest, any other name is production, and no name (dev, test)
  is `:local`, where everything is available. The other app's base URL is
  config `TalesForge.AppRole` (`:production_url`, `:playtest_url`).
  """

  alias TalesForge.Costs

  @typedoc "This app's role."
  @type role :: :production | :playtest | :local

  @typedoc "Data that lives on exactly one app."
  @type area :: :surveys | :playtest_runs

  @default_production_url "https://tales-forge.fly.dev"
  @default_playtest_url "https://tales-forge-playtest.fly.dev"

  @doc """
  This app's role, from its app name.

      iex> TalesForge.AppRole.role("tales-forge-playtest")
      :playtest
      iex> TalesForge.AppRole.role("tales-forge")
      :production
      iex> TalesForge.AppRole.role("local")
      :local
  """
  @spec role(String.t()) :: role()
  def role(app \\ Costs.app_name()) do
    cond do
      app == "local" -> :local
      Costs.playtest?(app) -> :playtest
      true -> :production
    end
  end

  @doc """
  The app that owns `area`: surveys live on production, playtest runs on playtest.

      iex> TalesForge.AppRole.home(:surveys)
      :production
      iex> TalesForge.AppRole.home(:playtest_runs)
      :playtest
  """
  @spec home(area()) :: :production | :playtest
  def home(:surveys), do: :production
  def home(:playtest_runs), do: :playtest

  @doc "True when `area`'s data lives on this app (always on `:local`)."
  @spec here?(area(), role()) :: boolean()
  def here?(area, role \\ role()), do: role == :local or role == home(area)

  @doc """
  The area an admin path belongs to, or nil: `/admin/survey`, `/admin/surveys`
  and below are `:surveys`; `/admin/playtest` and below are `:playtest_runs`.

      iex> TalesForge.AppRole.area_for_path("/admin/surveys/founder-survey-3/results.csv")
      :surveys
      iex> TalesForge.AppRole.area_for_path("/admin/playtest/abc")
      :playtest_runs
      iex> TalesForge.AppRole.area_for_path("/admin/sessions")
      nil
  """
  @spec area_for_path(String.t()) :: area() | nil
  def area_for_path(path) when is_binary(path) do
    case String.split(path, "/", trim: true) do
      ["admin", "survey" | _] -> :surveys
      ["admin", "surveys" | _] -> :surveys
      ["admin", "playtest" | _] -> :playtest_runs
      _ -> nil
    end
  end

  @doc """
  Where a request for `path` (with an optional `query`) should go instead: the
  same path on the app that owns it, or nil when it is served here.
  """
  @spec redirect_url(String.t(), String.t() | nil, role()) :: String.t() | nil
  def redirect_url(path, query \\ nil, role \\ role()) do
    case area_for_path(path) do
      nil ->
        nil

      area ->
        if here?(area, role), do: nil, else: url(home(area), path, query)
    end
  end

  @doc """
  Link to `path` for `area`: the path itself when the area lives here, else
  the full URL on the app that owns it.
  """
  @spec link(area(), String.t(), role()) :: String.t()
  def link(area, path, role \\ role()) do
    if here?(area, role), do: path, else: url(home(area), path, nil)
  end

  @doc "Base URL of the production or playtest app (config `TalesForge.AppRole`)."
  @spec base_url(:production | :playtest) :: String.t()
  def base_url(:production), do: config_url(:production_url, @default_production_url)
  def base_url(:playtest), do: config_url(:playtest_url, @default_playtest_url)

  @doc "Display name of the app that owns `area`, e.g. for a notice or nav label."
  @spec home_label(area()) :: String.t()
  def home_label(area), do: if(home(area) == :production, do: "production", else: "playtest")

  defp url(app, path, query) do
    base = base_url(app) |> String.trim_trailing("/")
    if query in [nil, ""], do: base <> path, else: base <> path <> "?" <> query
  end

  defp config_url(key, default) do
    case Application.get_env(:ex_tales_forge, __MODULE__, []) |> Keyword.get(key) do
      url when is_binary(url) and url != "" -> url
      _ -> default
    end
  end
end
