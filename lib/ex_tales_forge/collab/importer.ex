defmodule TalesForge.Collab.Importer do
  @moduledoc """
  Imports decisions and docs from a local checkout of `tales-forge-docs`,
  or fetches the private repo via the GitHub Contents API.
  Upserts by decision slug / doc path. Does not wipe comments or interests.
  """

  require Logger

  alias TalesForge.Collab.Schemas.{Decision, Doc}
  alias TalesForge.Repo

  @github_owner "whyse-ab"
  @github_repo "tales-forge-docs"

  def import_from_path(root) when is_binary(root) do
    root = Path.expand(root)

    unless File.dir?(root) do
      {:error, {:not_a_directory, root}}
    else
      decisions_dir = Path.join(root, "decisions")
      docs_dir = Path.join(root, "docs")

      decision_stats =
        if File.dir?(decisions_dir) do
          decisions_dir
          |> Path.join("*.md")
          |> Path.wildcard()
          |> Enum.reject(&(Path.basename(&1) == "README.md"))
          |> Enum.map(&import_decision_file/1)
          |> summarize()
        else
          %{upserted: 0, errors: []}
        end

      doc_stats =
        if File.dir?(docs_dir) do
          docs_dir
          |> Path.join("**/*.md")
          |> Path.wildcard()
          |> Enum.map(fn path ->
            rel = Path.relative_to(path, root)
            import_doc_file(path, rel)
          end)
          |> summarize()
        else
          %{upserted: 0, errors: []}
        end

      {:ok, %{decisions: decision_stats, docs: doc_stats}}
    end
  end

  def import_from_github(token, opts \\ []) when is_binary(token) do
    owner = Keyword.get(opts, :owner, @github_owner)
    repo = Keyword.get(opts, :repo, @github_repo)
    ref = Keyword.get(opts, :ref, "main")

    with {:ok, decision_files} <- list_github_dir(token, owner, repo, "decisions", ref),
         {:ok, doc_files} <- list_github_dir(token, owner, repo, "docs", ref) do
      decision_stats =
        decision_files
        |> Enum.filter(&String.ends_with?(&1["path"], ".md"))
        |> Enum.reject(&(&1["name"] == "README.md"))
        |> Enum.map(fn file ->
          case fetch_github_file(token, owner, repo, file["path"], ref) do
            {:ok, content} -> upsert_decision_markdown(content, file["path"])
            {:error, reason} -> {:error, {file["path"], reason}}
          end
        end)
        |> summarize()

      doc_stats =
        doc_files
        |> Enum.filter(&String.ends_with?(&1["path"], ".md"))
        |> Enum.map(fn file ->
          case fetch_github_file(token, owner, repo, file["path"], ref) do
            {:ok, content} -> upsert_doc_markdown(content, file["path"])
            {:error, reason} -> {:error, {file["path"], reason}}
          end
        end)
        |> summarize()

      {:ok, %{decisions: decision_stats, docs: doc_stats}}
    end
  end

  defp import_decision_file(path) do
    content = File.read!(path)
    upsert_decision_markdown(content, path)
  end

  defp import_doc_file(path, rel_path) do
    content = File.read!(path)
    upsert_doc_markdown(content, rel_path)
  end

  def upsert_decision_markdown(content, source_path) do
    with {:ok, attrs} <- parse_decision(content, source_path) do
      case Repo.get_by(Decision, slug: attrs.slug) do
        nil ->
          %Decision{}
          |> Decision.changeset(attrs)
          |> Repo.insert()
          |> then(fn
            {:ok, _} -> {:ok, :inserted}
            {:error, cs} -> {:error, {source_path, cs}}
          end)

        existing ->
          # Preserve DB-side outcome/rank if already decided or rank was moved in UI.
          # Content fields (title, options, body, links, status from git) refresh from git
          # unless the DB already recorded a decision outcome.
          merge =
            if existing.status == "decided" and present?(existing.decision) do
              Map.drop(attrs, [:status, :decision, :rationale, :decided_at, :rank])
            else
              # Keep UI rank if it differs from a previous sync? Prefer git rank on sync
              # so repo remains SoT for content; rank changes in UI are DB-local until export.
              Map.put(attrs, :rank, existing.rank)
            end

          existing
          |> Decision.changeset(merge)
          |> Repo.update()
          |> then(fn
            {:ok, _} -> {:ok, :updated}
            {:error, cs} -> {:error, {source_path, cs}}
          end)
      end
    end
  end

  def upsert_doc_markdown(content, path) do
    {title, body} = parse_doc(content, path)

    attrs = %{path: path, title: title, body: body}

    case Repo.get_by(Doc, path: path) do
      nil ->
        %Doc{}
        |> Doc.changeset(attrs)
        |> Repo.insert()
        |> then(fn
          {:ok, _} -> {:ok, :inserted}
          {:error, cs} -> {:error, {path, cs}}
        end)

      existing ->
        existing
        |> Doc.changeset(attrs)
        |> Repo.update()
        |> then(fn
          {:ok, _} -> {:ok, :updated}
          {:error, cs} -> {:error, {path, cs}}
        end)
    end
  end

  def parse_decision(content, source_path) do
    {fm, body} = split_frontmatter(content)

    slug =
      Map.get(fm, "id") ||
        source_path |> Path.basename(".md")

    title = Map.get(fm, "title") || slug
    rank = parse_int(Map.get(fm, "rank"), 999)
    status = Map.get(fm, "status") || "open"
    options = parse_string_list(Map.get(fm, "options"))
    links = parse_string_list(Map.get(fm, "links"))
    decision = blank_to_nil(Map.get(fm, "decision"))
    rationale = blank_to_nil(Map.get(fm, "rationale"))
    decided_at = parse_datetime(Map.get(fm, "decided_at"))

    {:ok,
     %{
       slug: to_string(slug),
       title: to_string(title),
       rank: rank,
       status: to_string(status),
       options: options,
       links: links,
       decision: decision,
       rationale: rationale,
       decided_at: decided_at,
       body: String.trim(body || ""),
       source_path: to_string(source_path)
     }}
  rescue
    e -> {:error, {source_path, Exception.message(e)}}
  end

  defp parse_doc(content, path) do
    {_fm, body} = split_frontmatter(content)
    body = String.trim(body || "")

    title =
      case Regex.run(~r/^#\s+(.+)$/m, body) do
        [_, t] -> String.trim(t)
        _ -> Path.basename(path, ".md")
      end

    {title, body}
  end

  defp split_frontmatter(content) do
    case Regex.run(~r/\A\s*---\s*\n(.*?)\n---\s*\n(.*)\z/s, content, capture: :all_but_first) do
      [yaml, body] ->
        fm =
          case YamlElixir.read_from_string(yaml) do
            {:ok, map} when is_map(map) -> stringify_keys(map)
            _ -> %{}
          end

        {fm, body}

      _ ->
        {%{}, content}
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp parse_string_list(nil), do: []

  defp parse_string_list(list) when is_list(list) do
    Enum.map(list, &stringify_list_item/1)
  end

  defp parse_string_list(str) when is_binary(str), do: [str]
  defp parse_string_list(map) when is_map(map), do: [stringify_list_item(map)]
  defp parse_string_list(_), do: []

  # YAML turns "Hybrid: new engine..." into %{"Hybrid" => "new engine..."}.
  defp stringify_list_item(item) when is_binary(item), do: item
  defp stringify_list_item(item) when is_atom(item), do: Atom.to_string(item)
  defp stringify_list_item(item) when is_number(item), do: to_string(item)

  defp stringify_list_item(map) when is_map(map) do
    Enum.map_join(map, ", ", fn {k, v} -> "#{k}: #{v}" end)
  end

  defp stringify_list_item(other), do: inspect(other)

  defp parse_int(nil, default), do: default
  defp parse_int(n, _) when is_integer(n), do: n

  defp parse_int(str, default) when is_binary(str) do
    case Integer.parse(String.trim(str)) do
      {n, _} -> n
      :error -> default
    end
  end

  defp parse_int(_, default), do: default

  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil

  defp parse_datetime(%DateTime{} = dt),
    do: DateTime.truncate(dt, :second)

  defp parse_datetime(%Date{} = d) do
    DateTime.new!(d, ~T[00:00:00], "Etc/UTC")
  end

  defp parse_datetime(str) when is_binary(str) do
    str = String.trim(str)

    cond do
      match?({:ok, _}, DateTime.from_iso8601(str)) ->
        {:ok, dt, _} = DateTime.from_iso8601(str)
        DateTime.truncate(dt, :second)

      match?({:ok, _}, Date.from_iso8601(str)) ->
        {:ok, d} = Date.from_iso8601(str)
        DateTime.new!(d, ~T[00:00:00], "Etc/UTC")

      true ->
        nil
    end
  end

  defp parse_datetime(_), do: nil

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v) when is_binary(v), do: v
  defp blank_to_nil(v), do: to_string(v)

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp summarize(results) do
    Enum.reduce(results, %{upserted: 0, errors: []}, fn
      {:ok, _}, acc -> %{acc | upserted: acc.upserted + 1}
      {:error, reason}, acc -> %{acc | errors: [reason | acc.errors]}
    end)
    |> then(fn acc -> %{acc | errors: Enum.reverse(acc.errors)} end)
  end

  defp list_github_dir(token, owner, repo, path, ref) do
    url = "https://api.github.com/repos/#{owner}/#{repo}/contents/#{path}?ref=#{ref}"

    case Req.get(url, headers: github_headers(token)) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:github_list_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_github_file(token, owner, repo, path, ref) do
    url = "https://api.github.com/repos/#{owner}/#{repo}/contents/#{path}?ref=#{ref}"

    case Req.get(url, headers: github_headers(token)) do
      {:ok, %{status: 200, body: %{"content" => content, "encoding" => "base64"}}} ->
        {:ok, Base.decode64!(String.replace(content, "\n", ""))}

      {:ok, %{status: status, body: body}} ->
        {:error, {:github_fetch_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp github_headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"user-agent", "tales-forge-collab-importer"}
    ]
  end
end
