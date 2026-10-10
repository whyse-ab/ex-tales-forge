defmodule TalesForge.Board.Events do
  @moduledoc """
  What a board change sets off, added to the same `Ecto.Multi` as the change
  (a transactional outbox: the jobs exist if and only if the change committed).

  `TalesForge.Board.Events.add/4` names the event; the jobs it inserts come with the bot pings and the
  decision log commit.
  """

  alias Ecto.Multi
  alias TalesForge.Board.Idea

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

  @doc "Adds the jobs of `event` on `idea` (with `extra` details) to `multi`."
  @spec add(Multi.t(), event(), Idea.t(), map()) :: Multi.t()
  def add(multi, _event, %Idea{}, _extra), do: multi
end
