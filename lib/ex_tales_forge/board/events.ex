defmodule TalesForge.Board.Events do
  @moduledoc """
  What a board change sets off, added to the same `Ecto.Multi` as the change
  (a transactional outbox: the jobs exist if and only if the change committed).

  | Event | Job |
  |---|---|
  | `:idea_to_refining`, `:idea_back_to_refining`, `:idea_pullable` | wake Case |
  | `:idea_to_building` | write the decision log entry, wake Bobby |
  | `:pr_link_added` (on a Building card) | wake Gentry to check the playtest |
  | `:mention` (`@case`, `@bobby`, `@gentry` in a comment) | wake that bot |
  | `:pr_approved`, `:pr_changes_requested` (a founder answers a PR) | wake Bobby |
  | `:idea_to_check`, `:idea_to_done` | nothing (founders see the board) |

  Bot wake-ups are `TalesForge.Board.Workers.Notify` jobs (signed webhook
  POSTs); the decision log entry is `TalesForge.Board.Workers.LogDecision`.
  """

  alias Ecto.Multi
  alias TalesForge.Board.Idea
  alias TalesForge.Board.Workers.{LogDecision, Notify}

  @typedoc "A board event."
  @type event ::
          :idea_to_refining
          | :idea_back_to_refining
          | :idea_pullable
          | :idea_to_check
          | :idea_to_building
          | :idea_to_done
          | :pr_link_added
          | :mention
          | :pr_approved
          | :pr_changes_requested

  @doc "Adds the jobs of `event` on `idea` (with `extra` details) to `multi`."
  @spec add(Multi.t(), event(), Idea.t(), map()) :: Multi.t()
  def add(multi, event, %Idea{} = idea, extra) do
    multi =
      if event == :idea_to_building,
        do:
          Oban.insert(
            multi,
            {:log_decision, idea.id},
            LogDecision.new(%{"idea_id" => idea.id, "founder" => extra[:actor]})
          ),
        else: multi

    Enum.reduce(bots(event, extra), multi, fn bot, acc ->
      Oban.insert(
        acc,
        {:notify, bot, event, System.unique_integer([:positive])},
        Notify.job(bot, event, idea, extra)
      )
    end)
  end

  @doc """
  The bots an event wakes.

      iex> TalesForge.Board.Events.bots(:idea_to_building, %{})
      [:bobby]
      iex> TalesForge.Board.Events.bots(:mention, %{bot: :gentry})
      [:gentry]
      iex> TalesForge.Board.Events.bots(:idea_to_done, %{})
      []
  """
  @spec bots(event(), map()) :: [TalesForge.BoardApi.bot()]
  def bots(event, _extra)
      when event in [:idea_to_refining, :idea_back_to_refining, :idea_pullable],
      do: [:case]

  def bots(:idea_to_building, _extra), do: [:bobby]
  def bots(:pr_link_added, _extra), do: [:gentry]
  def bots(:mention, %{bot: bot}), do: [bot]
  def bots(event, _extra) when event in [:pr_approved, :pr_changes_requested], do: [:bobby]
  def bots(_event, _extra), do: []
end
