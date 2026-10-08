defmodule TalesForge.Survey.Source do
  @moduledoc """
  Loads a survey definition (`TalesForge.Survey.Definition`) by id, from
  `docs/<id>.json` in tales-forge-docs, so a wording change is a docs commit
  and needs no deploy.

  Where it reads from, first match wins:

    1. a local docs checkout when `TALES_FORGE_DOCS_PATH` is set (development);
    2. otherwise GitHub (`whyse-ab/tales-forge-docs`, branch `main`) through the
       Contents API with the server's `GITHUB_DOCS_TOKEN`;
    3. otherwise, or when that fails, the snapshot shipped in
       `priv/surveys/<id>.json`.

  Results are cached for a minute (`TalesForge.Survey.Cache`). When the docs
  copy can't be fetched or doesn't validate, the last good copy (or the
  snapshot) is served and `problems` lists what went wrong, so the pages can
  show an admin error instead of crashing. `{:error, problems}` only when
  nothing usable is left.

  The docs sync (`mix tales.sync_docs`) is not used: it has been unreliable
  (it misses files), and the survey would silently go stale.
  """

  require Logger

  alias TalesForge.Survey.Cache
  alias TalesForge.Survey.Definition

  @api "https://api.github.com"
  @default_repo "whyse-ab/tales-forge-docs"
  @default_ref "main"
  @ttl_ms :timer.seconds(60)
  @error_ttl_ms :timer.seconds(20)

  @typedoc """
  A loaded definition: where it came from (`source`, human-readable), the
  SHA-256 of the exact file, and any `problems` with the preferred source.
  """
  @type loaded :: %{
          definition: Definition.t(),
          source: String.t(),
          sha256: String.t(),
          raw: String.t(),
          fetched_at: DateTime.t(),
          problems: [String.t()]
        }

  @doc """
  The survey `id`, from the cache when it is fresh. `fresh: true` skips the
  cache (the admin "Reload from docs" button).
  """
  @spec load(String.t(), keyword()) :: {:ok, loaded()} | {:error, [String.t()]}
  def load(id, opts \\ []) do
    if Definition.valid_id?(id), do: cached_load(id, opts), else: {:error, ["unknown survey"]}
  end

  @doc "Where the definition is read from for `id` (shown on the admin pages)."
  @spec describe(String.t()) :: String.t()
  def describe(id) do
    case primary() do
      {:path, path} -> "local docs checkout #{Path.join(path, doc_path(id))}"
      {:github, _token} -> "GitHub #{repo()}@#{ref()}:#{doc_path(id)} (cached 60 s)"
      :none -> "snapshot priv/surveys/#{id}.json (GITHUB_DOCS_TOKEN not set)"
    end
  end

  @doc "Absolute path of the snapshot shipped in the release for `id`."
  @spec snapshot_path(String.t()) :: String.t()
  def snapshot_path(id),
    do: Path.join(Application.app_dir(:ex_tales_forge, "priv/surveys"), "#{id}.json")

  defp cached_load(id, opts) do
    case if(opts[:fresh], do: :miss, else: Cache.get({:survey, id})) do
      {:fresh, loaded} -> {:ok, loaded}
      {:stale, loaded} -> fetch(id, loaded)
      :miss -> fetch(id, nil)
    end
  end

  defp fetch(id, previous) do
    case read_primary(id) do
      {:ok, raw, source} ->
        case Definition.parse(raw) do
          {:ok, definition} ->
            {:ok, Cache.put({:survey, id}, loaded(definition, raw, source, []), @ttl_ms)}

          {:error, errors} ->
            fallback(id, previous, Enum.map(errors, &"#{source}: #{&1}"))
        end

      {:error, problem} ->
        fallback(id, previous, [problem])

      :none ->
        from_snapshot(id, [])
    end
  end

  # Prefer the last good docs copy; else the snapshot. Never cache a fallback
  # for long, so a fixed docs commit shows up quickly.
  defp fallback(id, previous, problems) do
    Logger.warning("survey=#{id} definition problems: #{Enum.join(problems, "; ")}")

    case previous do
      %{problems: [], source: source} = loaded ->
        note = "showing the last good copy from #{source}"
        result = %{loaded | problems: problems ++ [note]}
        {:ok, Cache.put({:survey, id}, result, @error_ttl_ms)}

      _other ->
        case from_snapshot(id, problems) do
          {:ok, loaded} -> {:ok, Cache.put({:survey, id}, loaded, @error_ttl_ms)}
          error -> error
        end
    end
  end

  defp from_snapshot(id, problems) do
    path = snapshot_path(id)
    source = "snapshot priv/surveys/#{id}.json"
    note = if problems == [], do: [], else: ["showing the #{source} instead"]

    with {:ok, raw} <- File.read(path),
         {:ok, definition} <- Definition.parse(raw) do
      {:ok, loaded(definition, raw, source, problems ++ note)}
    else
      {:error, errors} when is_list(errors) ->
        {:error, problems ++ Enum.map(errors, &"#{source}: #{&1}")}

      {:error, :enoent} ->
        {:error, problems ++ ["no survey #{id} (no docs copy and no #{source})"]}

      {:error, reason} ->
        {:error, problems ++ ["#{source}: #{inspect(reason)}"]}
    end
  end

  defp loaded(definition, raw, source, problems) do
    %{
      definition: definition,
      raw: raw,
      source: source,
      sha256: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower),
      fetched_at: DateTime.utc_now(),
      problems: problems
    }
  end

  defp read_primary(id) do
    case primary() do
      {:path, path} -> read_local(Path.join(path, doc_path(id)))
      {:github, token} -> read_github(token, id)
      :none -> :none
    end
  end

  defp read_local(file) do
    case File.read(file) do
      {:ok, raw} -> {:ok, raw, "local docs checkout"}
      {:error, reason} -> {:error, "could not read #{file}: #{:file.format_error(reason)}"}
    end
  end

  defp read_github(token, id) do
    path = doc_path(id)
    url = "/repos/#{repo()}/contents/#{path}"

    case Req.get(github_req(token), url: url, params: [ref: ref()]) do
      {:ok, %{status: 200, body: %{"content" => content, "sha" => sha}}} ->
        case Base.decode64(String.replace(content, ~r/\s/, "")) do
          {:ok, raw} -> {:ok, raw, "tales-forge-docs #{ref()} (blob #{String.slice(sha, 0, 7)})"}
          :error -> {:error, "GitHub returned #{path} in an unexpected encoding"}
        end

      {:ok, %{status: 404}} ->
        {:error, "#{path} is not in #{repo()}@#{ref()}"}

      {:ok, %{status: status}} ->
        {:error, "GitHub answered HTTP #{status} for #{path}"}

      {:error, error} ->
        {:error, "GitHub request for #{path} failed: #{Exception.message(error)}"}
    end
  end

  defp github_req(token) do
    Req.new(
      [
        base_url: @api,
        headers: [
          {"authorization", "Bearer #{token}"},
          {"accept", "application/vnd.github+json"},
          {"x-github-api-version", "2022-11-28"},
          {"user-agent", "tales-forge-survey"}
        ],
        retry: false,
        receive_timeout: 5_000
      ] ++ Application.get_env(:ex_tales_forge, :survey_req_options, [])
    )
  end

  defp primary do
    path = Application.get_env(:ex_tales_forge, :tales_forge_docs_path)
    token = Application.get_env(:ex_tales_forge, :github_docs_token)

    cond do
      present?(path) -> {:path, path}
      present?(token) -> {:github, token}
      true -> :none
    end
  end

  defp doc_path(id), do: "docs/#{id}.json"
  defp repo, do: Application.get_env(:ex_tales_forge, :survey_docs_repo, @default_repo)
  defp ref, do: Application.get_env(:ex_tales_forge, :survey_docs_ref, @default_ref)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
