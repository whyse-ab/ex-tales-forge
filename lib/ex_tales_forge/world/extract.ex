defmodule TalesForge.World.Extract do
  @moduledoc """
  World agents round 2: new facts and NPC promises read from the finished GM
  narration, after the turn and off its critical path.

  One small LLM call (`TalesForge.LLM.complete_fact_extract/3`: purpose
  `fact_extract`, call_type llm, conv id `<session>:facts`) gets the turn's
  entities, their known facts, what the player character did and the
  narration, and returns typed facts (`fact`, `price`, `promise`). Elixir
  validates them (`TalesForge.World.validate_facts/3`: known entity, promise
  only for a person, no duplicate, no second price for the same thing),
  persists the accepted ones (`world_fact` session events, never shown to the
  player) and hands them to the running agents, so the next turn's facts
  include them. Validation and storage are timed as the function step
  `turn.world_writeback`.

  Jev can't write text, so this is an LLM call; it replaces the GM's own
  `new_facts` field from round 1, which the GM filled once in 20 turns.
  """

  require Logger

  alias TalesForge.AICalls.Steps
  alias TalesForge.LLM
  alias TalesForge.World

  @narration_chars 3_000

  @doc "Starts `run/5` after the turn (synchronously when `:world_extract_mode` is `:sync`, for tests)."
  def run_async(session_id, turn_number, raw_action, narrative, agents, tags) do
    fun = fn -> run(session_id, turn_number, raw_action, narrative, agents, tags) end

    case Application.get_env(:ex_tales_forge, :world_extract_mode, :async) do
      :sync -> fun.()
      _ -> Task.Supervisor.start_child(TalesForge.Playtest.Supervisor, fun)
    end

    :ok
  end

  @doc "Extracts, validates, stores and commits. Returns `{:ok, accepted}` or `{:error, reason}`."
  def run(session_id, turn_number, raw_action, narrative, agents, tags \\ %{}) do
    case LLM.complete_fact_extract(system(), user(agents, raw_action, narrative),
           session_id: session_id,
           turn_number: turn_number
         ) do
      {:ok, %{"facts" => facts}} when is_list(facts) ->
        started_at = DateTime.utc_now()
        t0 = System.monotonic_time(:microsecond)
        {accepted, rejected} = World.validate_facts(agents, clean(facts), turn_number)
        World.store_facts(session_id, accepted, turn_number)
        World.commit(session_id, accepted, [])

        Steps.record_one(
          Map.merge(tags, %{
            purpose: "turn.world_writeback",
            latency_ms: div(System.monotonic_time(:microsecond) - t0 + 500, 1_000),
            started_at: started_at,
            game_session_id: session_id,
            turn_number: turn_number
          })
        )

        Logger.info(
          "world facts extracted session=#{session_id} turn=#{turn_number} " <>
            "accepted=#{inspect(accepted)} rejected=#{inspect(rejected)}"
        )

        {:ok, accepted}

      {:ok, other} ->
        {:error, {:invalid_reply, other}}

      error ->
        Logger.warning(
          "world fact extraction failed session=#{session_id} reason=#{inspect(error)}"
        )

        error
    end
  rescue
    e ->
      Logger.warning(
        "world fact extraction crashed session=#{session_id} error=#{Exception.message(e)}"
      )

      {:error, :crashed}
  end

  def system,
    do: File.read!(Path.join(:code.priv_dir(:ex_tales_forge), "prompts/fact_extract_system.txt"))

  @doc false
  def user(agents, raw_action, narrative) do
    entities =
      Enum.map_join(agents, "\n", fn a -> "- #{a.id}: #{a.name} (#{a.kind}, #{role(a.role)})" end)

    known =
      agents
      |> Enum.flat_map(fn a -> Enum.map(a.facts, &"- #{a.id}: #{fact_line(&1)}") end)
      |> Enum.join("\n")

    """
    Entities:
    #{entities}

    Known facts:
    #{if known == "", do: "(none)", else: known}

    The player character did or said:
    #{raw_action |> to_string() |> String.slice(0, 600)}

    GM narration this turn:
    #{narrative |> to_string() |> String.slice(0, @narration_chars)}
    """
  end

  # Caps on the reply, applied here rather than as maxItems/maxLength in the schema.
  defp clean(facts) do
    facts
    |> Enum.filter(&(is_map(&1) and is_binary(&1["about"]) and is_binary(&1["text"])))
    |> Enum.take(3)
    |> Enum.map(fn f ->
      %{
        "about" => f["about"],
        "kind" => if(is_binary(f["kind"]), do: String.downcase(f["kind"]), else: "fact"),
        "text" => String.slice(f["text"], 0, 160)
      }
    end)
  end

  defp fact_line(%{"kind" => "promise", "text" => t}), do: "promised: " <> t
  defp fact_line(%{"text" => t}), do: t

  defp role(:here), do: "here"
  defp role(:present), do: "present"
  defp role(:held), do: "carried"
  defp role(_), do: "around"
end
