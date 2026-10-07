defmodule TalesForge.Playtest.Scorer do
  @moduledoc """
  Scores a finished playtest run.

  When `TYPESAFE_API_KEY` is set, the primary path is
  `TalesForge.Playtest.JevScorer` (persona-affect, player-visible text only).
  When the key is unset, falls back to the LLM rubric judge: one call reads the
  transcript plus server rolls and GM hidden notes, scores against the persona's
  scorecard from personas.md, and stores a `playtest_scores` row with evidence.

  Off unless `PLAYTEST_RUNNER_ENABLED=true`. Calls are recorded in ai_calls as
  `scorer`: outside the session cap and the game's cost, inside the day cap.
  """

  require Logger

  alias TalesForge.GameSessions
  alias TalesForge.LLM
  alias TalesForge.Playtest.{JevScorer, Personas, Reports, Runner}
  alias TalesForge.Repo
  alias TalesForge.Schemas.PlaytestScore

  @rubric "v1"
  @scoreable ~w(finished stopped)

  @system """
  You are the judge for Tales Forge playtests. A persona bot played a session of this text role-playing game against the AI Game Master. You score how well the game served that persona, using the persona's scorecard. You are not the Game Master and you do not continue the story.

  For each scorecard criterion, give a score from 1 to 5 (1 = clearly failed, 3 = mixed, 5 = clearly met), or null when this session gave no chance to test it. Base every score on the record and quote the turn behind it in evidence, for example: T3: "...". Judge the game, not the bot's play. In rationale, say in at most three sentences what most helped or hurt this persona.
  """

  def score(run_id) do
    if JevScorer.configured?() do
      JevScorer.score(run_id)
    else
      llm_score(run_id)
    end
  end

  defp llm_score(run_id) do
    case do_score(run_id) do
      {:ok, score} ->
        {:ok, score}

      {:error, reason} = error ->
        Logger.warning("playtest scoring failed run=#{run_id} reason=#{inspect(reason)}")
        error
    end
  end

  defp do_score(run_id) do
    with :ok <- if(Runner.enabled?(), do: :ok, else: {:error, :disabled}),
         {:ok, run} <- Reports.get_run(run_id),
         :ok <-
           if(run.status in @scoreable, do: :ok, else: {:error, {:not_scoreable, run.status}}),
         {:ok, persona} <- Personas.fetch(run.persona),
         {:ok, reply} <-
           LLM.complete_scorer(@system, prompt(run, persona),
             session_id: run.game_session_id,
             criteria: length(persona.scorecard)
           ),
         {:ok, scores, rationale} <- parse(reply, persona.scorecard) do
      %PlaytestScore{}
      |> PlaytestScore.changeset(%{
        playtest_run_id: run.id,
        model: LLM.tier2_model(),
        rubric_version: rubric_version(persona.scorecard),
        scores: scores,
        overall: overall(scores),
        rationale: rationale,
        source: "llm",
        kind: "rubric"
      })
      |> Repo.insert()
    end
  end

  @doc "Rubric version: `v1-` plus a short hash of the persona's scorecard text."
  def rubric_version(criteria) do
    hash = :crypto.hash(:sha256, Enum.join(criteria, "\n")) |> Base.encode16(case: :lower)
    "#{@rubric}-#{binary_part(hash, 0, 7)}"
  end

  defp prompt(run, persona) do
    criteria =
      persona.scorecard
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {criterion, n} -> "#{n}. #{criterion}" end)

    """
    Persona under test:

    #{persona.notes}

    Scorecard (score each criterion by its number):
    #{criteria}

    Run: module #{run.module}, #{run.turns_played} of #{run.turn_limit} turns played, stopped by #{run.stop_reason}.

    Session record. [Scene], [Player] and [GM] lines are what the player saw; (roll) and (GM notes) lines were hidden from the player.

    #{record(run.game_session_id)}
    """
  end

  defp record(session_id) do
    turns = session_id |> Reports.turn_records() |> Map.new(&{&1.id, &1})
    session = session_id |> GameSessions.get_session!() |> Repo.preload([:turns, :scenes])

    session
    |> GameSessions.transcript()
    |> Enum.map_join("\n", fn entry -> record_line(entry, turns) end)
  end

  defp record_line(%{role: "scene", text: text}, _turns), do: "[Scene] #{text}"

  defp record_line(%{id: id, role: role, text: text}, turns) do
    turn = Map.fetch!(turns, String.replace(id, ~r/-(player|gm)$/, ""))
    prefix = "T#{turn.turn_number}"

    case role do
      "player" -> "#{prefix} [Player] #{text}" <> hidden(prefix, "roll", turn.roll)
      "gm" -> "#{prefix} [GM] #{text}" <> hidden(prefix, "GM notes", turn.gm_notes)
    end
  end

  defp hidden(_prefix, _label, nil), do: ""
  defp hidden(prefix, label, text), do: "\n#{prefix} (#{label}) #{text}"

  defp parse(%{"scores" => scores, "rationale" => rationale}, criteria)
       when is_list(scores) and is_binary(rationale) do
    by_number = for %{"criterion" => n} = s <- scores, into: %{}, do: {n, s}

    card =
      criteria
      |> Enum.with_index(1)
      |> Map.new(fn {criterion, n} ->
        given = Map.get(by_number, n, %{})

        {"#{n}. #{criterion}",
         %{"score" => valid_score(given["score"]), "evidence" => given["evidence"]}}
      end)

    {:ok, card, rationale}
  end

  defp parse(reply, _criteria), do: {:error, {:invalid_scorecard, reply}}

  defp valid_score(score) when score in 1..5, do: score
  defp valid_score(_score), do: nil

  defp overall(scores) do
    case scores |> Map.values() |> Enum.map(& &1["score"]) |> Enum.reject(&is_nil/1) do
      [] -> nil
      given -> Float.round(Enum.sum(given) / length(given), 1)
    end
  end
end
