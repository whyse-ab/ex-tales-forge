defmodule TalesForge.Workers.ProcessTurn do
  @moduledoc """
  Oban worker for Tier 2 GM narration and turn persistence.

  Core runtime path. Uses Ecto-only game modules.
  """
  use Oban.Worker, queue: :llm, max_attempts: 3

  alias TalesForge.Game.TurnProcessor

  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{
            "session_id" => session_id,
            "raw_action" => raw_action,
            "player_action" => player_action
          } = args
      }) do
    # gm_quote: the GM's quote (TalesForge.Game.PlayerQuote); absent in the
    # baseline variant and in jobs enqueued before it existed.
    case TurnProcessor.run(session_id, raw_action, player_action, gm_quote: args["gm_quote"]) do
      {:ok, _payload} -> :ok
      {:error, {:spend_cap, _kind} = reason} -> {:cancel, reason}
      {:error, reason} -> {:error, reason}
    end
  end
end
