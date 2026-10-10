defmodule TalesForge.Board.Workers.AutoDone do
  @moduledoc """
  The board moves cards to Done by itself (Fredrik, 2026-10-10): after each
  production boot (every prod deploy boots the app), a Building card whose
  linked PR's merge commit is in the running release (`GIT_SHA`;
  `TalesForge.Board.OnProd`, the Done gate) moves to Done as `bot:board`,
  with a note that names the release. The move goes through
  `TalesForge.Board.move/4`, so `TalesForge.Board.Transitions` decides, and
  Done wakes no bot.

  - Production only (`TalesForge.AppRole`). `schedule_on_boot/0` queues one
    job 30 seconds after boot. `schedule/0` queues one more job when a PR
    link comes to a Building card or a card with a PR link moves to Building
    (`TalesForge.Board`), so a link added after the deploy also moves the card.
  - Idempotent: a card in Done is no longer in Building; a second run moves
    nothing.
  - GitHub down (or `GIT_SHA` unknown): the cards that can't be checked stay;
    the job fails and Oban tries again (backoff 1 min, doubling, up to 4 h).
  """
  use Oban.Worker,
    queue: :board,
    max_attempts: 10,
    unique: [period: 60, states: :incomplete]

  import Ecto.Query

  alias TalesForge.AppRole
  alias TalesForge.Board
  alias TalesForge.Board.{Idea, OnProd}
  alias TalesForge.Playtest.RunMeta
  alias TalesForge.Repo

  @doc "Queues the run 30 seconds after boot, on production only."
  @spec schedule_on_boot() :: :ok
  def schedule_on_boot do
    if AppRole.role() == :production do
      {:ok, _} = %{} |> new(schedule_in: 30) |> Oban.insert()
    end

    :ok
  end

  @doc """
  Queues a run in 5 seconds (production, or with `:board_auto_done_anywhere`).
  Not unique: a run that runs now may have read the cards before this change.
  """
  @spec schedule() :: :ok
  def schedule do
    if enabled?() do
      {:ok, _} = %{} |> new(schedule_in: 5, unique: false) |> Oban.insert()
    end

    :ok
  end

  defp enabled? do
    AppRole.role() == :production or
      Application.get_env(:ex_tales_forge, :board_auto_done_anywhere, false)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if enabled?() do
      case run() do
        {:ok, _moved} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: min(60 * Integer.pow(2, attempt - 1), 4 * 3600)

  @doc """
  Moves every Building card whose PR is in the running release to Done.
  `{:ok, ids}` of the moved cards, or `{:error, reason}` when some cards
  could not be checked (they stay in Building; the others still move).
  """
  @spec run() :: {:ok, [Ecto.UUID.t()]} | {:error, String.t()}
  def run do
    results =
      from(i in Idea, where: i.column == "building", select: i.id)
      |> Repo.all()
      |> Enum.map(&Board.get_idea!/1)
      |> Enum.map(&try_card/1)

    moved = for {:moved, id} <- results, do: id

    case for({:unavailable, reason} <- results, do: reason) do
      [] -> {:ok, moved}
      [reason | _] -> {:error, reason}
    end
  end

  defp try_card(idea) do
    number = Board.pr_number_of(idea)

    case number && OnProd.status(number) do
      :included ->
        case Board.move(idea, {:bot, :board}, "done", note(number)) do
          {:ok, _} -> {:moved, idea.id}
          {:error, reason} -> {:unavailable, to_string(reason)}
        end

      {:unavailable, reason} ->
        {:unavailable, reason}

      _ ->
        :stays
    end
  end

  @doc """
  The move note, naming the release.

      iex> System.put_env("GIT_SHA", "ae5df15279532c9f")
      iex> System.delete_env("FLY_IMAGE_REF")
      iex> TalesForge.Board.Workers.AutoDone.note(130)
      "PR #130 is in the prod release ae5df15. The board moved the card to Done."
      iex> System.delete_env("GIT_SHA")
      :ok
  """
  @spec note(pos_integer()) :: String.t()
  def note(number) do
    sha = (RunMeta.git_sha() || "unknown") |> String.slice(0, 7)

    image =
      case System.get_env("FLY_IMAGE_REF") do
        nil -> ""
        ref -> " (#{ref |> String.split(":") |> List.last()})"
      end

    "PR ##{number} is in the prod release #{sha}#{image}. The board moved the card to Done."
  end
end
