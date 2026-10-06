defmodule Mix.Tasks.Tales.SyncDocs do
  @moduledoc """
  Sync decisions and docs from tales-forge-docs into Postgres.

      mix tales.sync_docs
      mix tales.sync_docs --path /path/to/tales-forge-docs
      mix tales.sync_docs --github   # uses GITHUB_DOCS_TOKEN
  """

  use Mix.Task

  @shortdoc "Sync founder decisions/docs from the docs repo"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [path: :string, github: :boolean],
        aliases: [p: :path, g: :github]
      )

    result =
      cond do
        opts[:github] ->
          token = System.get_env("GITHUB_DOCS_TOKEN") || Mix.raise("GITHUB_DOCS_TOKEN not set")
          TalesForge.Collab.sync_from_github(token)

        path = opts[:path] || System.get_env("TALES_FORGE_DOCS_PATH") ->
          TalesForge.Collab.sync_from_path(path)

        File.dir?("/workspace/tales-forge-docs-git") ->
          TalesForge.Collab.sync_from_path("/workspace/tales-forge-docs-git")

        true ->
          Mix.raise("Pass --path PATH or set TALES_FORGE_DOCS_PATH / GITHUB_DOCS_TOKEN")
      end

    case result do
      {:ok, stats} ->
        Mix.shell().info(
          "Synced decisions=#{stats.decisions.upserted} docs=#{stats.docs.upserted}"
        )

        for err <- stats.decisions.errors ++ stats.docs.errors do
          Mix.shell().error("  error: #{inspect(err)}")
        end

      {:error, reason} ->
        Mix.raise("Sync failed: #{inspect(reason)}")
    end
  end
end
