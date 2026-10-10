defmodule TalesForge.Collab.Links do
  @moduledoc """
  Where a link in a tales-forge-docs page goes when the admin shows it.

  The docs are written for GitHub, so they link to each other with relative
  paths (`personas.md`, `../decisions/d-008-tin-valley-starter.md#why`,
  `images/score.png`, `scripts/jev-rescore/rescore.exs`). Rendered at
  `/admin/docs/...` those paths would resolve against the admin URL and 404.
  `rewrite/3` maps each one to the page that shows it:

  - a doc in the database: the doc viewer, `/admin/docs/<path under docs/>`;
  - a decision in the database: `/admin/founders/decisions/<slug>`;
  - an image under `docs/`: `/admin/docs-files/<repo path>`
    (`TalesForgeWeb.DocFilesController`, the repo is private);
  - anything else in the repo (scripts, JSON, a doc not synced yet): the file
    on GitHub, which team members can open.

  Absolute URLs, `mailto:`, same-page `#anchors` (headings get GitHub-style
  ids when rendered) and paths of this app (`/admin/play/runs`)
  are left alone.
  """

  @github "https://github.com/whyse-ab/tales-forge-docs"
  @images ~w(.png .jpg .jpeg .gif .webp)

  @typedoc """
  What the database has: doc paths (`docs/personas.md`) and decision file
  names mapped to slugs (`"d-008-tin-valley-starter.md" => "d-008-tin-valley-starter"`).
  """
  @type known :: %{docs: MapSet.t(String.t()), decisions: %{String.t() => String.t()}}

  @doc """
  Builds `t:known/0` from doc paths and `{source_path, slug}` decision pairs.
  """
  @spec known([String.t()], [{String.t() | nil, String.t()}]) :: known()
  def known(doc_paths, decisions) do
    %{
      docs: MapSet.new(doc_paths),
      decisions:
        Map.new(decisions, fn {source_path, slug} ->
          {Path.basename(source_path || slug <> ".md"), slug}
        end)
    }
  end

  @doc """
  The URL the admin should use for `url`, found in the repo file `source`
  (e.g. `docs/founder-survey-3.md`).

      iex> known = TalesForge.Collab.Links.known(["docs/personas.md"], [])
      iex> TalesForge.Collab.Links.rewrite("personas.md#paul", "docs/decisions.md", known)
      "/admin/docs/personas.md#paul"
      iex> TalesForge.Collab.Links.rewrite("scripts/run.exs", "docs/decisions.md", known)
      "https://github.com/whyse-ab/tales-forge-docs/blob/main/docs/scripts/run.exs"
      iex> TalesForge.Collab.Links.rewrite("#paul", "docs/personas.md", known)
      "#paul"
  """
  @spec rewrite(String.t(), String.t(), known()) :: String.t()
  def rewrite(url, source, known) when is_binary(url) and is_binary(source) do
    uri = URI.parse(url)

    cond do
      url == "" or String.starts_with?(url, ["#", "/"]) -> url
      uri.scheme != nil -> url
      true -> uri.path |> repo_path(source) |> target(uri.path, known) |> with_fragment(uri)
    end
  end

  # Repo-relative path of a link, resolved against the folder of the file it
  # is in.
  defp repo_path(nil, source), do: source

  defp repo_path(path, source), do: source |> Path.dirname() |> Path.join(path) |> normalize()

  defp normalize(path) do
    path
    |> String.split("/")
    |> Enum.reduce([], fn
      segment, acc when segment in ["", "."] -> acc
      "..", [_ | acc] -> acc
      "..", [] -> []
      segment, acc -> [segment | acc]
    end)
    |> Enum.reverse()
    |> Enum.join("/")
  end

  defp target(path, original, known) do
    ext = path |> Path.extname() |> String.downcase()

    cond do
      MapSet.member?(known.docs, path) ->
        "/admin/docs/" <> String.replace_prefix(path, "docs/", "")

      decision = decision_slug(path, known) ->
        "/admin/founders/decisions/" <> decision

      ext in @images and String.starts_with?(path, "docs/") ->
        "/admin/docs-files/" <> path

      ext == "" or String.ends_with?(original || "", "/") ->
        "#{@github}/tree/main/#{path}"

      true ->
        "#{@github}/blob/main/#{path}"
    end
  end

  defp decision_slug("decisions/" <> file, known), do: Map.get(known.decisions, file)
  defp decision_slug(_path, _known), do: nil

  defp with_fragment(url, %URI{fragment: nil}), do: url
  defp with_fragment(url, %URI{fragment: fragment}), do: url <> "#" <> fragment
end
