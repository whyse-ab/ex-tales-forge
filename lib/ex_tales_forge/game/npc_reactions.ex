defmodule TalesForge.Game.NpcReactions do
  @moduledoc """
  Prototype (`NPC_REACTIONS=on`, default off): an NPC's gut reaction (System 1)
  read by TypeSafe Jev **before** the GM call, so the GM's lines for that NPC
  follow a typed reaction instead of repeating the same brush-off.

  For each NPC present (at most #{4}), one Jev call, all concurrently
  (`Task.async_stream`, short timeout). Input, player-visible only:

  - the NPC's name, role, personality text and OCEAN scores (0–10);
  - her mood before this moment (the previous reaction, or neutral);
  - the narration the player last heard (latest turn or scene);
  - the player character's words/action this turn, and how the attempt came
    across (the server's outcome, e.g. a failed persuasion). Outcomes of
    checks the NPC cannot see (insight, history, arcana, tracking, survival,
    tactics) are left out, so a failed read never makes her warier.

  Never gm_notes, secrets, hidden events or memories marked secret.

  Output per NPC, a typed reaction: `emotion` (fixed labels), `intensity`
  0.0–1.0, `stance` (hostile, cool, neutral, warm, friendly) and `confidence`
  (the lower of Jev's emotion and stance confidences). A timeout or error
  means no reaction for that NPC; the turn goes on.

  The reactions go to the GM as one short line per NPC in the per-turn section
  (`prompt_section/1`); the mood carries over in the session's
  `world_state["npc_moods"]`. Each call is an `ai_calls` row with
  call_type `jev`, purpose `npc_reaction`.
  """

  require Logger

  import Ecto.Query

  alias TalesForge.AICalls
  alias TalesForge.Config
  alias TalesForge.Game.Variant
  alias TalesForge.NPC
  alias TalesForge.Repo
  alias TalesForge.Schemas.{Scene, Turn}

  @model "jev-1.13.0"
  @purpose "npc_reaction"
  @max_npcs 4
  @narration_chars 1_200
  @action_chars 600

  @emotions %{
    calm: "Even, unbothered, business as usual",
    curious: "Interested, wants to know more",
    amused: "Finds it funny or charming",
    sympathetic: "Moved, feels for the player character",
    wary: "Guarded, cautious, keeps her distance",
    suspicious: "Doubts their story or motives",
    irritated: "Annoyed, impatient, put out",
    afraid: "Scared or alarmed"
  }

  @intensity ["none", "slight", "moderate", "strong", "intense"]
  @stances ["hostile", "cool", "neutral", "warm", "friendly"]

  @typedoc """
  One NPC's reaction: `"npc_id"`, `"name"`, `"emotion"`, `"intensity"` (0..1),
  `"stance"`, `"stance_score"` (0..1), `"confidence"` and `"turn_number"`.
  """
  @type reaction :: %{optional(String.t()) => term()}

  @doc "The `ai_calls` purpose of a reaction call."
  @spec purpose() :: String.t()
  def purpose, do: @purpose

  @doc "The emotions a reaction can have, sorted."
  @spec emotions() :: [String.t()]
  def emotions, do: @emotions |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

  @doc "The stances, from hostile to friendly."
  @spec stances() :: [String.t()]
  def stances, do: @stances

  @doc """
  On when `NPC_REACTIONS` (or `WORLD_AGENTS`, where this is a Person agent's
  System 1 reaction) is on and a TypeSafe key is configured.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: (Config.npc_reactions?() or Config.world_agents?()) and configured?()

  @doc """
  True when a TypeSafe (Jev) API key is configured in `config :jev, :api_key`
  (`config/runtime.exs` sets it from `TYPESAFE_API_KEY` outside test). The OS
  environment is not read here, so tests decide the key with `Application.put_env/3`.
  """
  @spec configured?() :: boolean()
  def configured? do
    case Application.get_env(:jev, :api_key) do
      key when is_binary(key) and key != "" -> true
      _ -> false
    end
  end

  @doc """
  Reactions of the NPCs present in `world` this turn, and `world` with their
  moods carried over in `"npc_moods"`. Returns `{reactions, world}`;
  `{[], world}` when off, nobody is present, or every call failed.
  """
  @spec react(String.t(), map(), integer(), String.t(), struct() | nil) :: {[reaction()], map()}
  def react(session_id, world, turn_number, raw_action, mechanical) do
    present = List.wrap(world["present_npcs"])

    npcs =
      if enabled?() and present != [] do
        session_id
        |> NPC.list_instances()
        |> Enum.filter(&(&1.npc_id in present))
        |> Enum.take(@max_npcs)
      else
        []
      end

    if npcs == [] do
      {[], world}
    else
      moods = world["npc_moods"] || %{}
      scene = situation(session_id, raw_action, visible_outcome(mechanical, world))
      reactions = run_all(npcs, moods, scene, session_id, turn_number)
      {reactions, put_moods(world, moods, reactions, turn_number)}
    end
  end

  defp run_all(npcs, moods, scene, session_id, turn_number) do
    timeout = Config.npc_reactions_timeout_ms()

    npcs
    |> Task.async_stream(
      fn inst ->
        call_one(inst, Map.get(moods, inst.npc_id), scene, session_id, turn_number, timeout)
      end,
      max_concurrency: length(npcs),
      timeout: timeout + 500,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(npcs)
    |> Enum.flat_map(fn
      {{:ok, {:ok, r}}, _inst} ->
        Logger.info(
          "npc reaction session=#{session_id} turn=#{turn_number} npc=#{r["npc_id"]} " <>
            "emotion=#{r["emotion"]} intensity=#{r["intensity"]} stance=#{r["stance"]} " <>
            "stance_score=#{r["stance_score"]} confidence=#{r["confidence"]}"
        )

        [r]

      {{:ok, {:error, reason}}, inst} ->
        Logger.warning("npc reaction failed npc=#{inst.npc_id} reason=#{inspect(reason)}")
        []

      {{:exit, reason}, inst} ->
        Logger.warning("npc reaction timed out npc=#{inst.npc_id} reason=#{inspect(reason)}")
        record(session_id, turn_number, "error", timeout + 500, %{})
        []
    end)
  end

  defp call_one(inst, mood, scene, session_id, turn_number, timeout) do
    started = System.monotonic_time(:millisecond)

    result =
      Jev.HTTP.post(state(inst, mood, scene), questions(inst),
        model: @model,
        max_retries: 0,
        receive_timeout: timeout
      )

    elapsed = System.monotonic_time(:millisecond) - started

    case result do
      {:ok, reply} ->
        record(session_id, turn_number, "ok", elapsed, reply)
        {:ok, reaction(inst, reply, turn_number)}

      {:error, reason} ->
        record(session_id, turn_number, "error", elapsed, %{})
        {:error, reason}
    end
  rescue
    e -> {:error, {:crashed, Exception.message(e)}}
  end

  # --- input --------------------------------------------------------------------

  @doc false
  @spec situation(String.t(), String.t(), struct() | nil) :: %{
          narration: String.t() | nil,
          action: String.t(),
          outcome: String.t() | nil
        }
  def situation(session_id, raw_action, mechanical) do
    %{
      narration: last_narration(session_id),
      action: raw_action |> to_string() |> String.trim() |> String.slice(0, @action_chars),
      outcome: outcome_text(mechanical)
    }
  end

  @doc false
  @spec state(struct(), map() | nil, map()) :: String.t()
  def state(inst, mood, scene) do
    definition = inst.personality || %{}
    traits = get_in(definition, ["motivations", "personality_traits"]) || %{}

    ocean =
      ~w(openness conscientiousness extraversion agreeableness neuroticism)
      |> Enum.map_join(", ", &"#{&1} #{Map.get(traits, &1, "?")}")

    [
      "NPC: #{name(inst)} (#{definition["role"] || inst.npc_id}).",
      definition["personality"] && "Personality: #{definition["personality"]}",
      "OCEAN (0-10): #{ocean}.",
      "Mood before this moment: #{mood_text(mood)}.",
      scene.narration && "What #{name(inst)} last saw and heard (narration):\n#{scene.narration}",
      "What the player character says or does now:\n#{scene.action}",
      scene.outcome && "How it comes across: #{scene.outcome}."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  @doc false
  @spec questions(struct()) :: list()
  def questions(inst) do
    n = name(inst)

    [
      emotion:
        {"Which feeling does #{n} most likely have right now, in reaction to what the player character just said or did?",
         @emotions},
      intensity: {"How strong is that feeling in #{n}?", @intensity},
      stance: {"After this moment, what is #{n}'s stance toward the player character?", @stances}
    ]
  end

  defp last_narration(session_id) do
    turn =
      Repo.one(
        from t in Turn,
          where: t.game_session_id == ^session_id,
          order_by: [desc: t.turn_number],
          limit: 1,
          select: {t.inserted_at, t.narrative}
      )

    scene =
      Repo.one(
        from s in Scene,
          where: s.game_session_id == ^session_id,
          order_by: [desc: s.inserted_at],
          limit: 1,
          select: {s.inserted_at, s.narrative}
      )

    [turn, scene]
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(fn {at, _} -> at end, DateTime, fn -> {nil, nil} end)
    |> elem(1)
    |> case do
      nil -> nil
      text -> String.slice(text, -@narration_chars, @narration_chars)
    end
  end

  # A failed read, search or recall happens in the player character's head:
  # the NPC never sees it, so it must not make her warier (decision
  # 2026-10-07). The baseline variant passes every outcome on, as before.
  @unseen_skills ~w(insight history arcana tracking survival tactics)

  @doc false
  @spec visible_outcome(struct() | nil, map()) :: struct() | nil
  def visible_outcome(%{skill: skill} = mechanical, world) when skill in @unseen_skills do
    if Variant.baseline?(world), do: mechanical
  end

  def visible_outcome(mechanical, _world), do: mechanical

  defp outcome_text(%{outcome: outcome} = mechanical) when outcome not in [nil, "none"] do
    case mechanical.skill do
      nil -> to_string(outcome)
      skill -> "#{outcome} (#{skill} attempt)"
    end
  end

  defp outcome_text(_mechanical), do: nil

  defp mood_text(%{"emotion" => emotion} = mood) when is_binary(emotion),
    do: "#{emotion} (#{mood["intensity"]}), stance #{mood["stance"]}"

  defp mood_text(_mood), do: "neutral"

  # --- output -------------------------------------------------------------------

  @doc false
  @spec reaction(struct(), map(), integer()) :: reaction()
  def reaction(inst, reply, turn_number) do
    confidence = Map.get(reply, :confidence) || %{}

    %{
      "npc_id" => inst.npc_id,
      "name" => name(inst),
      "emotion" => label(reply[:emotion]),
      "intensity" => scale(reply[:intensity], length(@intensity)),
      "stance" => level(reply[:stance], @stances),
      "stance_score" => scale(reply[:stance], length(@stances)),
      "confidence" => min_confidence([confidence[:emotion], confidence[:stance]]),
      "turn_number" => turn_number
    }
  end

  defp put_moods(world, _moods, [], _turn_number), do: world

  defp put_moods(world, moods, reactions, _turn_number) do
    updated =
      Enum.reduce(reactions, moods, fn r, acc ->
        Map.put(
          acc,
          r["npc_id"],
          Map.take(r, ~w(emotion intensity stance confidence turn_number))
        )
      end)

    Map.put(world, "npc_moods", updated)
  end

  @doc """
  The per-turn prompt section for this turn's reactions, or nil. One short
  typed line per NPC, e.g. `- Brenna Holt — wary (0.7), stance cool, confidence 0.8`.
  """
  @spec prompt_section([reaction()] | nil) :: String.t() | nil
  def prompt_section([]), do: nil
  def prompt_section(nil), do: nil

  def prompt_section(reactions) when is_list(reactions) do
    lines =
      Enum.map_join(reactions, "\n", fn r ->
        "- #{r["name"]} — #{r["emotion"]} (#{fmt(r["intensity"])}), stance #{r["stance"]}, confidence #{fmt(r["confidence"])}"
      end)

    "## NPC reactions (this moment)\n" <> lines
  end

  defp record(session_id, turn_number, status, latency_ms, reply) do
    usage = Map.get(reply, :usage) || %{}
    input = usage[:input_tokens] || 0

    # Jev bills input tokens only (~$0.042 per 1M input tokens).
    cost_micro =
      case usage[:cost] do
        c when is_number(c) -> round(c * 1_000_000)
        _ -> round(input * 0.042)
      end

    AICalls.record(%{
      purpose: @purpose,
      call_type: "jev",
      model: Map.get(reply, :model) || @model,
      status: status,
      latency_ms: latency_ms,
      game_session_id: session_id,
      turn_number: turn_number,
      usage: %{input_tokens: input, output_tokens: 0, cost_ticks: cost_micro * 10_000}
    })
  end

  defp name(inst), do: get_in(inst.personality || %{}, ["name"]) || inst.npc_id

  defp label(nil), do: nil
  defp label(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp label(other), do: to_string(other)

  # Jev Score is a 0-indexed fractional level.
  defp scale(x, levels) when is_number(x),
    do: Float.round(min(max(x, 0), levels - 1) / (levels - 1), 2)

  defp scale(_x, _levels), do: nil

  defp level(x, labels) when is_number(x),
    do: Enum.at(labels, x |> round() |> max(0) |> min(length(labels) - 1))

  defp level(_x, _labels), do: nil

  defp min_confidence(values) do
    case Enum.filter(values, &is_number/1) do
      [] -> nil
      nums -> nums |> Enum.min() |> Float.round(2)
    end
  end

  defp fmt(nil), do: "?"
  defp fmt(x) when is_float(x), do: :erlang.float_to_binary(Float.round(x, 1), decimals: 1)
  defp fmt(x), do: to_string(x)
end
