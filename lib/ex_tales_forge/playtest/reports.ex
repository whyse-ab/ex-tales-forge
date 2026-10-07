defmodule TalesForge.Playtest.Reports do
  @moduledoc """
  Read side of playtest runs: the runs list, per-turn records with the hidden
  GM notes, cost per AI purpose and the latest scorecard. Admin and judge only;
  never shown to players.
  """

  import Ecto.Query

  alias TalesForge.AICalls
  alias TalesForge.GMReasoning
  alias TalesForge.Repo
  alias TalesForge.Schemas.{AICall, PlaytestRun, PlaytestScore, Turn}

  @runs_shown 100

  def list_runs do
    runs =
      PlaytestRun
      |> order_by(desc: :started_at)
      |> limit(@runs_shown)
      |> Repo.all()

    costs = session_costs(Enum.map(runs, & &1.game_session_id))
    scores = latest_scores(Enum.map(runs, & &1.id))

    Enum.map(runs, fn run ->
      %{
        run: run,
        game_cost_micro_usd: Map.get(costs, run.game_session_id, 0),
        score: Map.get(scores, run.id)
      }
    end)
  end

  def get_run(id) do
    with {:ok, id} <- Ecto.UUID.cast(id), %PlaytestRun{} = run <- Repo.get(PlaytestRun, id) do
      {:ok, run}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Headline score for a run: newest Jev `session_affect` if any, else newest LLM
  `rubric` row (or any other kind as a last resort).
  """
  def latest_score(run_id), do: run_id |> List.wrap() |> latest_scores() |> Map.get(run_id)

  @doc "Jev per-turn affect rows for a run, oldest turn first."
  def turn_affect_scores(run_id) do
    PlaytestScore
    |> where([s], s.playtest_run_id == ^run_id and s.kind == "turn_affect")
    |> order_by([s], asc: s.turn_number, desc: s.inserted_at)
    |> Repo.all()
    |> Enum.uniq_by(& &1.turn_number)
    |> Enum.sort_by(& &1.turn_number)
  end

  @doc "Turns in order, each with its server roll and hidden GM notes (nil when missing)."
  def turn_records(session_id) do
    notes =
      session_id
      |> GMReasoning.list_for_session()
      |> Map.new(&{&1.payload["turn_number"], &1.payload["gm_notes"]})

    Turn
    |> where([t], t.game_session_id == ^session_id)
    |> order_by(:turn_number)
    |> Repo.all()
    |> Enum.map(fn turn ->
      %{
        id: turn.id,
        turn_number: turn.turn_number,
        player_action: turn.player_action,
        narrative: turn.narrative,
        roll: roll_text(turn.mechanical_resolution || %{}),
        gm_notes: Map.get(notes, turn.turn_number)
      }
    end)
  end

  @doc "The GM's opening narration the player (or persona) saw before turn 1, or nil."
  def opening(session_id) do
    case TalesForge.GameSessions.opening_scene(session_id) do
      nil -> nil
      scene -> %{location_name: scene.location_name, narrative: scene.narrative}
    end
  end

  @doc "Calls, cost, tokens, latency and capped/error counts per AI purpose for a session."
  def cost_by_purpose(session_id) do
    AICall
    |> where([c], c.game_session_id == ^session_id)
    |> group_by([c], c.purpose)
    |> order_by([c], c.purpose)
    |> select([c], %{
      purpose: c.purpose,
      calls: count(c.id),
      cost_micro_usd: type(coalesce(sum(c.cost_micro_usd), 0), :integer),
      input_tokens: type(coalesce(sum(c.input_tokens), 0), :integer),
      output_tokens: type(coalesce(sum(c.output_tokens), 0), :integer),
      latency_ms: type(coalesce(sum(c.latency_ms), 0), :integer),
      capped: filter(count(c.id), c.status == "capped"),
      errors: filter(count(c.id), c.status == "error")
    })
    |> Repo.all()
  end

  def roll_text(%{"roll" => roll} = mechanical) when is_integer(roll) do
    against =
      if mechanical["effective_skill"], do: " vs #{mechanical["effective_skill"]}", else: ""

    [mechanical["skill"], "d20 #{roll}#{against}", mechanical["outcome"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  def roll_text(%{"outcome" => outcome}) when outcome not in [nil, "none"], do: outcome
  def roll_text(_mechanical), do: nil

  defp session_costs([]), do: %{}

  defp session_costs(session_ids) do
    AICall
    |> where([c], c.game_session_id in ^session_ids and c.purpose not in ^AICalls.bot_purposes())
    |> group_by([c], c.game_session_id)
    |> select([c], {c.game_session_id, type(coalesce(sum(c.cost_micro_usd), 0), :integer)})
    |> Repo.all()
    |> Map.new()
  end

  defp latest_scores([]), do: %{}

  defp latest_scores(run_ids) do
    PlaytestScore
    |> where([s], s.playtest_run_id in ^run_ids)
    |> where([s], s.kind in ^["session_affect", "rubric"])
    |> order_by([s], [
      s.playtest_run_id,
      asc: fragment("CASE WHEN ? = 'session_affect' THEN 0 ELSE 1 END", s.kind),
      desc: s.inserted_at,
      desc: s.id
    ])
    |> distinct([s], s.playtest_run_id)
    |> Repo.all()
    |> Map.new(&{&1.playtest_run_id, &1})
  end
end
