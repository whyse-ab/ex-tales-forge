defmodule TalesForge.Board.Workers.LogDecision do
  @moduledoc """
  Writes the decision log entry when a founder moves a card to Building (the
  founder OK): one commit to `docs/decisions.md` on `main` of
  whyse-ab/tales-forge-docs through the GitHub Contents API, as the board's
  GitHub App (`TalesForge.Board.GitHubApp`). Never a force push: the update
  names the file's blob sha, so a concurrent change makes GitHub answer 409
  and the job retries on the new file.

  Idempotent: the entry ends with `<!-- board:idea:<id> -->`; when that marker
  is already in the file (a retry after a lost answer) nothing is committed and
  the file's latest commit is recorded. The commit sha, the decision slug and a
  "Decision log" link are stored on the card (`TalesForge.Board.record_decision/4`),
  with a line in its history.

  Without the App configured the job is cancelled and the card gets a comment
  saying the entry wasn't written. Queue `:board`, unique per card.
  """

  use Oban.Worker,
    queue: :board,
    max_attempts: 10,
    unique: [
      keys: [:idea_id],
      period: :infinity,
      states: :incomplete
    ]

  alias TalesForge.Board
  alias TalesForge.Board.{GitHubApp, Idea}

  @repo "whyse-ab/tales-forge-docs"
  @path "docs/decisions.md"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"idea_id" => id} = args}) do
    idea = Board.get_idea!(id)

    cond do
      idea.decision_sha ->
        :ok

      GitHubApp.config() == nil ->
        {:ok, _} =
          Board.add_comment(
            idea,
            "bot:board",
            "Decision log entry not written: the GitHub App isn't set up yet."
          )

        {:cancel, :github_app_not_configured}

      true ->
        write(idea, args["founder"] || "a founder")
    end
  end

  defp write(idea, founder) do
    with {:ok, token} <- GitHubApp.token(),
         {:ok, %{"content" => content, "sha" => blob}} <- get_file(token) do
      text = content |> String.replace("\n", "") |> Base.decode64!()
      today = Date.utc_today()

      commit_unless_present(token, idea, founder, text, blob, today)
    end
  end

  defp commit_unless_present(token, idea, founder, text, blob, today) do
    slug = slug(today, idea.title)

    if String.contains?(text, marker(idea)) do
      with {:ok, sha} <- latest_commit(token), do: record(idea, slug, sha)
    else
      put_file(
        token,
        idea,
        founder,
        insert_entry(text, entry(idea, founder, today), today),
        blob,
        slug
      )
    end
  end

  defp get_file(token) do
    case Req.get(
           "#{GitHubApp.api()}/repos/#{@repo}/contents/#{@path}?ref=main",
           [headers: GitHubApp.headers(token), retry: false] ++ GitHubApp.req_options()
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:get, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp latest_commit(token) do
    case Req.get(
           "#{GitHubApp.api()}/repos/#{@repo}/commits?path=#{@path}&sha=main&per_page=1",
           [headers: GitHubApp.headers(token), retry: false] ++ GitHubApp.req_options()
         ) do
      {:ok, %{status: 200, body: [%{"sha" => sha} | _]}} -> {:ok, sha}
      {:ok, %{status: status}} -> {:error, {:commits, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp put_file(token, idea, founder, text, blob, slug) do
    body = %{
      "message" => "Decision log: #{idea.title} (idea board, OK by #{founder})",
      "content" => Base.encode64(text),
      "sha" => blob,
      "branch" => "main",
      "author" => %{"name" => founder, "email" => author_email(founder)}
    }

    case Req.put(
           "#{GitHubApp.api()}/repos/#{@repo}/contents/#{@path}",
           [json: body, headers: GitHubApp.headers(token), retry: false] ++
             GitHubApp.req_options()
         ) do
      {:ok, %{status: status, body: %{"commit" => %{"sha" => sha}}}} when status in [200, 201] ->
        record(idea, slug, sha)

      {:ok, %{status: status}} ->
        {:error, {:put, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record(idea, slug, sha) do
    url = "https://github.com/#{@repo}/commit/#{sha}"
    with {:ok, _} <- Board.record_decision(idea, slug, sha, url), do: :ok
  end

  defp author_email(founder),
    do: if(String.contains?(founder, "@"), do: founder, else: "board@tales-forge.invalid")

  @doc "The marker that makes the entry idempotent."
  @spec marker(Idea.t()) :: String.t()
  def marker(%Idea{id: id}), do: "<!-- board:idea:#{id} -->"

  @doc """
  The decision's slug: the date and the title.

      iex> TalesForge.Board.Workers.LogDecision.slug(~D[2026-10-10], "Brenna remembers regulars!")
      "2026-10-10-brenna-remembers-regulars"
  """
  @spec slug(Date.t(), String.t()) :: String.t()
  def slug(date, title) do
    words =
      title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 60)

    Date.to_iso8601(date) <> "-" <> words
  end

  @doc "The entry for `idea`, OK'd by `founder` on `date` (Markdown, ends with the marker)."
  @spec entry(Idea.t(), String.t(), Date.t()) :: String.t()
  def entry(%Idea{} = idea, founder, date) do
    r = idea.refinement || %{}

    summary =
      idea.body
      |> to_string()
      |> String.split(~r/\n\s*\n/, parts: 2)
      |> hd()
      |> String.replace("\n", " ")
      |> String.trim()

    why =
      [
        r["details"],
        r["verdict"] && "Verdict: #{String.replace(r["verdict"], "_", " ")}.",
        r["rough_cost"] && "Rough cost: #{r["rough_cost"]}."
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")

    """
    ## #{Date.to_iso8601(date)}: #{idea.title}

    - **Decision (#{founder}, #{Date.to_iso8601(date)}, on the idea board):** build it.#{if summary != "", do: " " <> summary, else: ""}
    - **Why:** #{if why == "", do: "the founders agreed on the board.", else: why}
    - **Link:** [the card on the idea board](#{Board.url(idea)})

    #{marker(idea)}
    """
  end

  @doc """
  `text` (decisions.md) with `entry` inserted as the newest entry (before the
  first second-level heading, or at the end) and the front matter's `updated:`
  set to `date`.
  """
  @spec insert_entry(String.t(), String.t(), Date.t()) :: String.t()
  def insert_entry(text, entry, date) do
    text =
      Regex.replace(~r/^updated: .*$/m, text, "updated: #{Date.to_iso8601(date)}", global: false)

    case :binary.match(text, "\n## ") do
      {pos, _} ->
        {head, rest} = String.split_at(text, pos + 1)
        head <> String.trim_trailing(entry) <> "\n\n" <> rest

      :nomatch ->
        String.trim_trailing(text) <> "\n\n" <> entry
    end
  end
end
