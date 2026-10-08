defmodule Mix.Tasks.Docs.CheckLinks do
  @moduledoc """
  Checks the internal links of a built ExDoc site, as the browser resolves them
  under `/admin/code-docs/` (`TalesForgeWeb.CodeDocsController`).

      mix docs
      mix docs.check_links            # checks doc/
      mix docs.check_links priv/code_docs

  Every `href` and `src` in every page, plus the sidebar and search entries
  (`dist/sidebar_items-*.js`, `dist/search_data-*.js`), must point at a file in
  the site, and a `#fragment` at an id on that page. A link that climbs out of
  the prefix (`../text-forge`) counts as broken. External links (`https:`,
  `mailto:`) are not fetched, so the check needs no network. Exits non-zero and
  lists every broken link otherwise. CI runs it after `mix docs`.
  """

  use Mix.Task

  @shortdoc "Checks the internal links of the ExDoc output"

  @prefix "/admin/code-docs/"

  @typedoc "A broken link: the page it is on, the link as written and why."
  @type broken :: %{page: String.t(), link: String.t(), reason: String.t()}

  @impl Mix.Task
  def run(args) do
    dir =
      case args do
        [dir | _] -> dir
        [] -> "doc"
      end

    unless File.dir?(dir), do: Mix.raise("#{dir} is not a directory; run `mix docs` first")

    case check(dir) do
      [] ->
        Mix.shell().info("docs.check_links: every internal link in #{dir} resolves")

      broken ->
        Enum.each(broken, fn b ->
          Mix.shell().error("#{b.page}: #{b.link} (#{b.reason})")
        end)

        Mix.raise("docs.check_links: #{length(broken)} broken link(s) in #{dir}")
    end
  end

  @doc """
  The broken internal links of the ExDoc site in `dir`, sorted by page; `[]`
  when every link resolves.
  """
  @spec check(Path.t()) :: [broken()]
  def check(dir) do
    pages = html_pages(dir)
    ids = Map.new(pages, fn {rel, html} -> {rel, ids(html)} end)

    page_links = for {rel, html} <- pages, link <- links(html), do: {rel, rel, link}

    (page_links ++ data_links(dir))
    |> Enum.uniq()
    |> Enum.flat_map(fn {page, base, link} ->
      case resolve(dir, ids, base, link) do
        :ok -> []
        {:error, reason} -> [%{page: page, link: link, reason: reason}]
      end
    end)
    |> Enum.sort_by(&{&1.page, &1.link})
  end

  defp html_pages(dir) do
    dir
    |> Path.join("**/*.html")
    |> Path.wildcard()
    |> Map.new(fn file -> {Path.relative_to(file, dir), File.read!(file)} end)
  end

  defp ids(html) do
    ~r/\s(?:id|name)="([^"]*)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> MapSet.new(fn [id] -> unescape(id) end)
  end

  defp links(html) do
    ~r/\s(?:href|src)="([^"]*)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> Enum.map(fn [link] -> unescape(link) end)
  end

  # Sidebar nodes (pages and their sections, functions, types) and search
  # results are built by ExDoc's JS from these data files, not from <a> tags.
  # Their links are relative to the page showing them (a top-level page).
  defp data_links(dir) do
    sidebar = data_file(dir, "dist/sidebar_items-*.js", "sidebarNodes=")
    search = data_file(dir, "dist/search_data-*.js", "searchData=")

    sidebar_links =
      for {_kind, nodes} <- sidebar || %{},
          is_list(nodes),
          node <- nodes,
          link <- node_links(node),
          do: {"sidebar", "index.html", link}

    search_links =
      for item <- (search || %{})["items"] || [],
          ref = item["ref"],
          is_binary(ref),
          do: {"search", "index.html", ref}

    sidebar_links ++ search_links
  end

  defp data_file(dir, pattern, assignment) do
    case dir |> Path.join(pattern) |> Path.wildcard() do
      [file | _] ->
        file |> File.read!() |> String.replace_prefix(assignment, "") |> Jason.decode!()

      [] ->
        nil
    end
  end

  defp node_links(%{"id" => id} = node) do
    page = id <> ".html"

    sections =
      for %{"anchor" => anchor} <- node["sections"] || [], do: page <> "#" <> anchor

    members =
      for %{"nodes" => nodes} <- node["nodeGroups"] || [],
          %{"anchor" => anchor} <- nodes,
          do: page <> "#" <> anchor

    [page | sections ++ members]
  end

  defp node_links(_node), do: []

  # Resolve the link against the URL of the page it is on (under the prefix),
  # then look for the file (and the fragment's id) in the site.
  defp resolve(dir, ids, page, link) do
    base = URI.parse("http://docs.local" <> @prefix <> page)
    uri = URI.parse(link)

    if link == "" or uri.scheme != nil or String.starts_with?(link, "//") do
      :ok
    else
      target = URI.merge(base, uri)
      path = URI.decode(target.path || "")

      if String.starts_with?(path, @prefix) do
        path |> String.replace_prefix(@prefix, "") |> check_target(dir, ids, target.fragment)
      else
        {:error, "resolves to #{path}, outside #{@prefix}"}
      end
    end
  end

  defp check_target(rel, dir, ids, fragment) do
    rel = if rel == "" or String.ends_with?(rel, "/"), do: rel <> "index.html", else: rel

    cond do
      not File.regular?(Path.join(dir, rel)) ->
        {:error, "no file #{rel}"}

      fragment in [nil, ""] or not Map.has_key?(ids, rel) ->
        :ok

      MapSet.member?(ids[rel], URI.decode(fragment)) ->
        :ok

      true ->
        {:error, "no id \"#{URI.decode(fragment)}\" in #{rel}"}
    end
  end

  defp unescape(text) do
    text
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end
end
