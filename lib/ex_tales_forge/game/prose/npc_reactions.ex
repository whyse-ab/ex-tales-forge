defmodule TalesForge.Game.Prose.NpcReactions do
  @moduledoc """
  Prose GM prototype (`GM_REPLY_MODE=prose`): per-NPC stance and emotion read
  from the GM's prose by TypeSafe Jev, instead of the GM writing bookkeeping.

  One Jev call per turn, four questions per present NPC (at most
  #{6}): does the NPC appear or react (yes/no probability), stance toward
  the player character (choice), dominant emotion (choice), and intensity
  (score). Input is the narrative plus each NPC's name, role, OCEAN traits and
  previous mood. Jev only classifies against fixed labels: it cannot write
  memories, facts or summaries.

  Runs off the turn's critical path. The result is stored as a player-unaware
  `npc_reaction` session event and applied to the world state at the start of
  the next prose turn (`apply_latest/2`), so it never races the turn's own
  world-state write. Usage is recorded in `ai_calls` as purpose `jev_npc`.
  """

  require Logger

  alias TalesForge.AICalls
  alias TalesForge.Game.Prose.Events
  alias TalesForge.NPC

  @kind "npc_reaction"
  @model "jev-1.13.0"
  @max_npcs 6
  @slots for i <- 0..(@max_npcs - 1),
             field <- ~w(present stance emotion intensity),
             into: %{},
             do: {{i, field}, String.to_atom("npc#{i}_#{field}")}

  @stances %{
    hostile: "Openly against the player character: threatening, refusing, or attacking",
    wary: "Guarded or suspicious; keeps distance, gives little",
    neutral: "Indifferent or businesslike",
    warm: "Somewhat open; willing to help or talk",
    friendly: "Clearly on the player character's side; trusting or eager"
  }

  @emotions %{
    calm: "Even, unbothered",
    fear: "Afraid, nervous, anxious",
    anger: "Angry, irritated, resentful",
    suspicion: "Distrustful, watchful, doubting",
    sadness: "Sad, weary, grieving",
    joy: "Pleased, amused, relieved",
    trust: "Reassured, grateful, confiding"
  }

  @intensity ["none", "mild", "moderate", "strong"]

  @doc "True when a TypeSafe key is configured."
  def configured? do
    case Application.get_env(:jev, :api_key) || System.get_env("TYPESAFE_API_KEY") do
      key when is_binary(key) and key != "" -> true
      _ -> false
    end
  end

  @doc "Starts `extract/4` under the task supervisor (fire and forget)."
  def extract_async(session_id, turn_number, narrative, present_npc_ids) do
    if configured?() and present_npc_ids != [] do
      Task.Supervisor.start_child(TalesForge.Playtest.Supervisor, fn ->
        extract(session_id, turn_number, narrative, present_npc_ids)
      end)
    end

    :ok
  end

  @doc """
  Asks Jev about each present NPC and stores the reactions. Returns
  `{:ok, reactions}` or `{:error, reason}`.
  """
  def extract(session_id, turn_number, narrative, present_npc_ids) do
    npcs =
      session_id
      |> NPC.list_instances()
      |> Enum.filter(&(&1.npc_id in present_npc_ids))
      |> Enum.take(@max_npcs)

    if npcs == [] do
      {:ok, []}
    else
      started = System.monotonic_time(:millisecond)
      result = Jev.HTTP.post(state(narrative, npcs), questions(npcs), model: @model)
      elapsed = System.monotonic_time(:millisecond) - started
      record_usage(session_id, turn_number, result, elapsed)

      case result do
        {:ok, reply} ->
          reactions = reactions(reply, npcs)
          store(session_id, turn_number, reactions)
          {:ok, reactions}

        {:error, reason} ->
          Logger.warning(
            "jev npc reactions failed session=#{session_id} reason=#{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  rescue
    e ->
      Logger.warning(
        "jev npc reactions crashed session=#{session_id} error=#{Exception.message(e)}"
      )

      {:error, :crashed}
  end

  @doc false
  def state(narrative, npcs) do
    people =
      Enum.map_join(Enum.with_index(npcs), "\n", fn {inst, i} ->
        definition = inst.personality || %{}
        traits = get_in(definition, ["motivations", "personality_traits"]) || %{}
        mood = (inst.runtime_state || %{})["mood"]

        ocean =
          ~w(openness conscientiousness extraversion agreeableness neuroticism)
          |> Enum.map_join(", ", &"#{&1} #{Map.get(traits, &1, "?")}/10")

        "NPC #{i}: #{name(inst)} (#{definition["role"] || inst.npc_id}); OCEAN: #{ocean}; mood before: #{mood || "unknown"}"
      end)

    "People present:\n#{people}\n\nGM text (this turn):\n#{narrative}"
  end

  @doc false
  def questions(npcs) do
    npcs
    |> Enum.with_index()
    |> Enum.flat_map(fn {inst, i} ->
      n = name(inst)

      [
        {@slots[{i, "present"}],
         "Does NPC #{i} (#{n}) appear, speak, or visibly react in the GM text?"},
        {@slots[{i, "stance"}],
         {"At the end of the GM text, what is NPC #{i} (#{n})'s stance toward the player character?",
          @stances}},
        {@slots[{i, "emotion"}],
         {"Which emotion does NPC #{i} (#{n}) most show in the GM text?", @emotions}},
        {@slots[{i, "intensity"}],
         {"How strong is NPC #{i} (#{n})'s emotion in the GM text?", @intensity}}
      ]
    end)
  end

  @doc false
  def reactions(reply, npcs) do
    confidence = Map.get(reply, :confidence, %{})

    npcs
    |> Enum.with_index()
    |> Enum.map(fn {inst, i} ->
      [present, stance, emotion, intensity] =
        Enum.map(~w(present stance emotion intensity), &@slots[{i, &1}])

      %{
        "npc_id" => inst.npc_id,
        "name" => name(inst),
        "present" => round3(reply[present]),
        "stance" => label(reply[stance]),
        "stance_confidence" => round3(confidence[stance]),
        "emotion" => label(reply[emotion]),
        "emotion_confidence" => round3(confidence[emotion]),
        "intensity" => round3(reply[intensity]),
        "intensity_label" => intensity_label(reply[intensity])
      }
    end)
  end

  @doc """
  Prose mode, start of a turn: puts the latest stored reactions (NPCs Jev saw
  in the last GM text) into `world["npc_reactions"]` for the per-turn prompt.
  """
  def apply_latest(world, session_id) do
    case latest(session_id) do
      nil ->
        world

      %{"reactions" => reactions, "turn_number" => turn} ->
        seen = Enum.filter(reactions, &((&1["present"] || 0) >= 0.5))
        Map.put(world, "npc_reactions", %{"turn_number" => turn, "reactions" => seen})
    end
  end

  @doc "Prompt lines for `world[\"npc_reactions\"]`, or nil."
  def prompt_section(%{"npc_reactions" => %{"reactions" => [_ | _] = reactions} = r}) do
    lines =
      Enum.map_join(reactions, "\n", fn x ->
        "- #{x["name"]} (#{x["npc_id"]}): #{x["stance"]}, #{x["emotion"]} (#{x["intensity_label"]})"
      end)

    "## NPC reactions after turn #{r["turn_number"]} (read from your narration)\n#{lines}"
  end

  def prompt_section(_world), do: nil

  def latest(session_id), do: Events.latest(session_id, @kind)

  def list_for_session(session_id), do: Events.list(session_id, @kind)

  defp store(session_id, turn_number, reactions) do
    Events.insert(session_id, @kind, "jev", %{
      "turn_number" => turn_number,
      "reactions" => reactions
    })
  end

  defp record_usage(session_id, turn_number, result, elapsed) do
    {status, reply} =
      case result do
        {:ok, reply} -> {"ok", reply}
        _ -> {"error", %{}}
      end

    usage = Map.get(reply, :usage) || %{}
    input = usage[:input_tokens] || 0

    cost_micro =
      case usage[:cost] do
        c when is_number(c) -> round(c * 1_000_000)
        _ -> round(input * 0.042)
      end

    AICalls.record(%{
      purpose: "jev_npc",
      model: Map.get(reply, :model) || @model,
      status: status,
      latency_ms: elapsed,
      game_session_id: session_id,
      turn_number: turn_number,
      usage: %{input_tokens: input, output_tokens: 0, cost_ticks: cost_micro * 10_000}
    })
  end

  defp name(inst), do: get_in(inst.personality || %{}, ["name"]) || inst.npc_id

  defp label(nil), do: nil
  defp label(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp label(other), do: to_string(other)

  defp intensity_label(x) when is_number(x),
    do: Enum.at(@intensity, x |> round() |> max(0) |> min(length(@intensity) - 1))

  defp intensity_label(_), do: nil

  defp round3(x) when is_float(x), do: Float.round(x, 3)
  defp round3(x), do: x
end
