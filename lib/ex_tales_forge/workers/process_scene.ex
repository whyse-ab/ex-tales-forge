defmodule TalesForge.Workers.ProcessScene do
  @moduledoc """
  Oban worker for opening scene narration before player turns.

  Core runtime. Ecto + Game modules only.
  """
  use Oban.Worker,
    queue: :llm,
    max_attempts: 3,
    unique: [period: 60, fields: [:args], keys: [:session_id], states: :incomplete]

  alias TalesForge.Game.SceneProcessor

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"session_id" => session_id}}) do
    case SceneProcessor.run(session_id) do
      {:ok, _} -> :ok
      {:error, {:spend_cap, _kind} = reason} -> {:cancel, reason}
      {:error, reason} -> {:error, reason}
    end
  end
end
