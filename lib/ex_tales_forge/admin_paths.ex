defmodule TalesForge.AdminPaths do
  @moduledoc """
  The admin pages that moved when the admin area was grouped by purpose
  (2026-10-10): each old path prefix and where it lives now.

  Every old URL keeps working: the router sends the old prefixes, and
  everything below them, to `TalesForgeWeb.AdminRedirectController`, which
  redirects to `canonical/1` of the path (query string kept, temporary 302 so a
  revert can't be stuck behind a cached permanent redirect).

  Links to the other app (surveys live on production, playtest runs on
  playtest; `TalesForge.AppRole`) use `legacy/1` of the path: the old path is
  understood by every version of either app, so a cross-app link works even
  while the two apps run different commits.

  Pure, no database; shared code (not an admin-lane file), because the router
  and the one-place redirects (`TalesForgeWeb.Plugs.HomeApp`) use it.
  """

  # {old first segment under /admin, new segments under /admin}
  @moves [
    {"sessions", ["play", "sessions"]},
    {"playtest", ["play", "runs"]},
    {"survey", ["founders", "survey"]},
    {"surveys", ["founders", "surveys"]},
    {"decisions", ["founders", "decisions"]},
    {"costs", ["operate", "costs"]},
    {"oban", ["operate", "telemetry"]},
    {"npc-definitions", ["archive", "npc-definitions"]}
  ]

  @doc """
  The moved prefixes as `{old, new}` paths.

      iex> TalesForge.AdminPaths.moves() |> Enum.take(2)
      [{"/admin/sessions", "/admin/play/sessions"}, {"/admin/playtest", "/admin/play/runs"}]
  """
  @spec moves() :: [{String.t(), String.t()}]
  def moves do
    for {old, new} <- @moves, do: {"/admin/" <> old, "/admin/" <> Enum.join(new, "/")}
  end

  @doc "The old first segments under `/admin` (for the router's redirect routes)."
  @spec old_segments() :: [String.t()]
  def old_segments, do: Enum.map(@moves, &elem(&1, 0))

  @doc """
  Where an admin `path` lives now: the path with its old prefix swapped for the
  new one, or the path itself when it didn't move. Whole segments only, so
  `/admin/survey` and `/admin/surveys` move separately; a trailing slash is kept.

      iex> TalesForge.AdminPaths.canonical("/admin/playtest/abc")
      "/admin/play/runs/abc"
      iex> TalesForge.AdminPaths.canonical("/admin/surveys/founder-survey-3/results.csv")
      "/admin/founders/surveys/founder-survey-3/results.csv"
      iex> TalesForge.AdminPaths.canonical("/admin/survey")
      "/admin/founders/survey"
      iex> TalesForge.AdminPaths.canonical("/admin/oban/home")
      "/admin/operate/telemetry/home"
      iex> TalesForge.AdminPaths.canonical("/admin/docs/personas.md")
      "/admin/docs/personas.md"
      iex> TalesForge.AdminPaths.canonical("/admin/play/runs/abc")
      "/admin/play/runs/abc"
  """
  @spec canonical(String.t()) :: String.t()
  def canonical(path) when is_binary(path) do
    case split(path) do
      ["admin", old | rest] ->
        case List.keyfind(@moves, old, 0) do
          {^old, new} -> join(["admin" | new] ++ rest, path)
          nil -> path
        end

      _other ->
        path
    end
  end

  @doc """
  The old path of a moved admin `path` (the inverse of `canonical/1`), or the
  path itself. Used for links to the other app (see the moduledoc).

      iex> TalesForge.AdminPaths.legacy("/admin/founders/survey")
      "/admin/survey"
      iex> TalesForge.AdminPaths.legacy("/admin/play/runs/abc")
      "/admin/playtest/abc"
      iex> TalesForge.AdminPaths.legacy("/admin/playtest/abc")
      "/admin/playtest/abc"
  """
  @spec legacy(String.t()) :: String.t()
  def legacy(path) when is_binary(path) do
    segments = split(path)

    Enum.find_value(@moves, path, fn {old, new} ->
      prefix = ["admin" | new]

      if List.starts_with?(segments, prefix),
        do: join(["admin", old | Enum.drop(segments, length(prefix))], path)
    end)
  end

  defp split(path), do: String.split(path, "/", trim: true)

  defp join(segments, original) do
    joined = "/" <> Enum.join(segments, "/")
    if String.ends_with?(original, "/"), do: joined <> "/", else: joined
  end
end
