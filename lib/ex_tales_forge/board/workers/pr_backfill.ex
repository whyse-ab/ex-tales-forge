defmodule TalesForge.Board.Workers.PrBackfill do
  @moduledoc """
  Each open normal-lane PR on a Building card waits for a founder's OK, with
  the "PR waiting for approval" badge and the Approve and Request changes
  buttons (Fredrik, 2026-10-10, card 6d08cf7e).

  `TalesForge.Board.link_pr/1` marks a PR as waiting. A PR can also come to a
  card as a plain `pr` link (`TalesForge.Board.add_link/3`), for example a
  link from before the approval badge. This job finds those cards and asks
  GitHub about each PR:

  - The PR is open (not merged, not closed): continue.
  - The PR is in the normal lane: its changed files are not all on the
    `[admin]` list of `.github/deploy-lanes.txt` on `main`
    (`TalesForge.DeployLanes`). A fast-lane PR needs no OK.

  Then `TalesForge.Board.mark_pr_waiting/4` marks the PR at its current head
  sha. A merged or closed PR gets no Approve button.

  - Production only (`TalesForge.AppRole`), or with
    `:board_pr_backfill_anywhere`. `schedule_on_boot/0` queues one job 30
    seconds after boot: this is the backfill for the links that are on the
    board now. `schedule/0` queues one more job when a PR link comes to a
    Building card or a card with a PR link moves to Building.
  - Idempotent: a marked card has a PR number; the next run skips it.
  - GitHub down (or no `GITHUB_FEED_TOKEN`): the cards that can't be checked
    stay as they are; the job fails and Oban tries again (backoff 1 min,
    doubling, up to 4 h).
  """
  use Oban.Worker,
    queue: :board,
    max_attempts: 10,
    unique: [period: 60, states: :incomplete]

  import Ecto.Query

  alias TalesForge.AppRole
  alias TalesForge.Board
  alias TalesForge.Board.{GitHubApp, Idea}
  alias TalesForge.DeployLanes
  alias TalesForge.PrFeed
  alias TalesForge.Repo

  @lanes_path ".github/deploy-lanes.txt"
  @page 100
  @max_pages 30

  @typedoc "What the job found for one card."
  @type outcome :: {:marked, Ecto.UUID.t()} | :stays | {:unavailable, String.t()}

  @doc "Queues the run 30 seconds after boot, on production only."
  @spec schedule_on_boot() :: :ok
  def schedule_on_boot, do: queue(30, [])

  @doc """
  Queues a run in 5 seconds. Not unique: a run that runs now may have read
  the cards before this change.
  """
  @spec schedule() :: :ok
  def schedule, do: queue(5, unique: false)

  defp queue(seconds, opts) do
    if enabled?() do
      {:ok, _} = %{} |> new([schedule_in: seconds] ++ opts) |> Oban.insert()
    end

    :ok
  end

  defp enabled? do
    AppRole.role() == :production or
      Application.get_env(:ex_tales_forge, :board_pr_backfill_anywhere, false)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if enabled?() do
      case run() do
        {:ok, _marked} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: min(60 * Integer.pow(2, attempt - 1), 4 * 3600)

  @doc """
  Marks the open normal-lane PR of each Building card that has a `pr` link but
  no PR waiting yet. `{:ok, ids}` of the marked cards, or `{:error, reason}`
  when some cards could not be checked (the job tries again; the other cards
  are marked).
  """
  @spec run() :: {:ok, [Ecto.UUID.t()]} | {:error, String.t()}
  def run do
    case candidates() do
      [] -> {:ok, []}
      cards -> run(cards, PrFeed.token())
    end
  end

  defp run(_cards, nil), do: {:error, "The board cannot read GitHub now (no GITHUB_FEED_TOKEN)."}

  defp run(cards, token) do
    case lanes(token) do
      {:ok, lanes} ->
        results = Enum.map(cards, &try_card(&1, token, lanes))
        marked = for {:marked, id} <- results, do: id

        case for({:unavailable, reason} <- results, do: reason) do
          [] -> {:ok, marked}
          [reason | _] -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Building cards with a `pr` link and no PR number yet.
  defp candidates do
    from(i in Idea, where: i.column == "building" and is_nil(i.pr_number), select: i.id)
    |> Repo.all()
    |> Enum.map(&Board.get_idea!/1)
    |> Enum.filter(&(Board.pr_number_of(&1) != nil))
  end

  @spec try_card(Idea.t(), String.t(), DeployLanes.t()) :: outcome()
  defp try_card(idea, token, lanes) do
    number = Board.pr_number_of(idea)

    with {:ok, pr} <- pull(token, number),
         {:open, %{"head" => %{"sha" => sha}, "html_url" => url}} <- {:open, open(pr)},
         {:ok, files} <- files(token, number),
         {:lane, :normal} <- {:lane, DeployLanes.classify(lanes, files).lane} do
      case Board.mark_pr_waiting(idea, number, url, sha) do
        {:ok, _} -> {:marked, idea.id}
        {:error, reason} -> {:unavailable, to_string(reason)}
      end
    else
      {:open, _} -> :stays
      {:lane, :admin} -> :stays
      {:error, reason} -> {:unavailable, reason}
    end
  end

  # Only an open, unmerged PR with a head sha and a URL waits for an OK.
  defp open(%{"state" => "open", "merged" => merged} = pr) when merged in [false, nil], do: pr
  defp open(_pr), do: nil

  defp pull(token, number) do
    case get(token, "/repos/#{PrFeed.repo()}/pulls/#{number}") do
      {:ok, pr} when is_map(pr) -> {:ok, pr}
      _ -> {:error, "GitHub did not answer for PR ##{number}. Try again later."}
    end
  end

  defp files(token, number), do: files(token, number, 1, [])

  defp files(_token, number, page, _acc) when page > @max_pages,
    do: {:error, "PR ##{number} has too many files to read."}

  defp files(token, number, page, acc) do
    path = "/repos/#{PrFeed.repo()}/pulls/#{number}/files?per_page=#{@page}&page=#{page}"

    case get(token, path) do
      {:ok, list} when is_list(list) ->
        names = Enum.flat_map(list, &file_names/1)
        acc = acc ++ names

        if length(list) < @page,
          do: {:ok, acc},
          else: files(token, number, page + 1, acc)

      _ ->
        {:error, "GitHub did not give the files of PR ##{number}. Try again later."}
    end
  end

  # A rename counts as delete + add (`.github/deploy-lanes.txt`).
  defp file_names(%{"filename" => name, "previous_filename" => old}), do: [name, old]
  defp file_names(%{"filename" => name}), do: [name]
  defp file_names(_), do: []

  defp lanes(token) do
    case get(token, "/repos/#{PrFeed.repo()}/contents/#{@lanes_path}?ref=main") do
      {:ok, %{"content" => content}} when is_binary(content) ->
        case content |> String.replace(~r/\s/, "") |> Base.decode64() do
          {:ok, text} -> {:ok, DeployLanes.parse(text)}
          :error -> {:error, "The board cannot read #{@lanes_path}."}
        end

      _ ->
        {:error, "GitHub did not give #{@lanes_path}. Try again later."}
    end
  end

  defp get(token, path) do
    case Req.get(
           [
             url: "https://api.github.com" <> path,
             headers: [
               {"authorization", "Bearer " <> token},
               {"accept", "application/vnd.github+json"}
             ],
             retry: false,
             receive_timeout: 10_000
           ] ++ GitHubApp.req_options()
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      _ -> :error
    end
  end
end
