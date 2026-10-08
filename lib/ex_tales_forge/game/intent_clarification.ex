defmodule TalesForge.Game.IntentClarification do
  @moduledoc """
  The act / ask decision for a Jev intent reading, and the templated question
  shown when the game asks.

  A turn acts when the read is confident (`>= act_min`), asks only when it is
  unsure (`< ask_below`) **and** the two most likely readings would play out
  differently, and otherwise plays its best guess. "Differently" means the top
  two action types fall in different consequence classes (talk is cheap to get
  wrong; a fight, a move, or spending coin is not), or, for a move or a fight,
  the target read itself is unsure, so the top two targets compete. At most one
  question per turn: the caller never asks again on the answer
  (`TalesForge.IntentJev`). See `tales-forge-docs/docs/design-jev-intent.md` §4.

  The question payload keeps the shape of
  `TalesForge.Game.Intent.build_clarification/2`, so the LiveView and the
  persona bot read it unchanged; it adds `"source" => "jev"` and, per option,
  the typed actions that option plays (`"option_actions"`).
  """

  alias TalesForge.Game.JevIntent
  alias TalesForge.Game.Schemas.SingleAction

  @default_act_min 0.70
  @default_ask_below 0.45
  # Two move/fight targets compete when the runner-up is this close to the top.
  @target_margin 0.25

  # Getting the class wrong is what a wrong guess costs the player. Talk-like
  # actions are cheap; the others commit the character to something.
  @classes %{
    speak: :talk,
    observe: :talk,
    interact: :talk,
    use_item: :talk,
    freeform: :talk,
    other: :talk,
    move: :move,
    combat: :combat,
    buy: :coin,
    sell: :coin,
    trade: :coin,
    spend: :coin,
    pickup: :items,
    drop: :items,
    wait: :time,
    train: :time
  }

  @verbs %{
    observe: "look around",
    interact: "handle",
    use_item: "use",
    pickup: "pick up",
    drop: "drop",
    buy: "buy",
    sell: "sell",
    trade: "trade",
    spend: "pay",
    wait: "wait",
    train: "train",
    freeform: "do something else",
    other: "do something else"
  }

  @typedoc "The turn's decision for a reading: act on it, play a best guess, or ask."
  @type decision :: :act | :best_guess | :ask

  @doc "The consequence class of an action type."
  @spec class(atom()) :: atom()
  def class(action), do: Map.get(@classes, action, :talk)

  @doc """
  The decision for a `t:TalesForge.Game.JevIntent.reading/0`.

  `opts` may set `:act_min` (default #{@default_act_min}) and `:ask_below`
  (default #{@default_ask_below}).
  """
  @spec band(JevIntent.reading(), keyword()) :: decision()
  def band(reading, opts \\ []) do
    act_min = Keyword.get(opts, :act_min, @default_act_min)
    ask_below = Keyword.get(opts, :ask_below, @default_ask_below)
    confidence = reading.confidence || 1.0

    cond do
      confidence >= act_min -> :act
      confidence < ask_below and split_class?(reading) -> :ask
      true -> :best_guess
    end
  end

  # True when the top two readings would commit the character to different
  # kinds of consequence, or a move or fight whose target is itself unsure (so
  # a wrong guess is worth a question).
  defp split_class?(%{top2: [a, b | _]} = reading) when a != b do
    class(a) != class(b) or split_target?(reading)
  end

  defp split_class?(reading), do: split_target?(reading)

  defp split_target?(%{action: action} = reading) when action in [:move, :combat] do
    case target_ranking(reading) do
      [{_first, p1}, {_second, p2} | _] -> p2 > 0 and p1 - p2 < @target_margin
      _ -> false
    end
  end

  defp split_target?(_reading), do: false

  @doc """
  The clarification payload for a reading over `candidates`: a templated
  question offering the top two readings ("Do you want to talk to Brenna Holt,
  or go to Market Square?"), matching the shape
  `TalesForge.Game.Intent.build_clarification/2` returns, plus `"source"` and
  `"option_actions"` (each option's typed actions, primary first).
  """
  @spec build(JevIntent.reading(), [JevIntent.candidate()]) :: map()
  def build(reading, candidates) do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    readings = readings(reading, candidates)

    %{
      "clarification_id" => id,
      "source" => "jev",
      "question" =>
        "Do you want to #{Enum.map_join(readings, ", or ", &phrase(&1, candidates))}?",
      "options" =>
        readings
        |> Enum.with_index()
        |> Enum.map(fn {r, idx} ->
          %{
            "id" => "option_#{idx}",
            "label" => Atom.to_string(r.action_type),
            "description" => phrase(r, candidates),
            "action_index" => idx
          }
        end),
      "option_actions" =>
        Enum.map(readings, fn r -> Enum.map(option_actions(r, reading), &encode_action/1) end),
      "allow_free_text" => true,
      "overall_intent" => reading.extraction.overall_intent,
      "confidence" => reading.confidence,
      "raw_action" => reading.extraction.overall_intent,
      "actions" => Enum.map(reading.extraction.actions, &encode_action/1)
    }
  end

  # The two readings offered: the top action with its target, and either the
  # runner-up action (with the best target of a kind it can take) or, when
  # the actions agree and the target is what is unsure, the runner-up target.
  defp readings(reading, candidates) do
    [first_type | rest] = Enum.uniq(reading.top2 ++ [reading.action])
    primary = List.first(reading.extraction.actions)
    first = %SingleAction{primary | action_type: first_type}

    second =
      case {rest, target_ranking(reading)} do
        {[second_type | _], _} when second_type != first_type ->
          if class(second_type) == class(first_type) and split_target?(reading),
            do: runner_up_target(first, reading),
            else: %SingleAction{
              action_type: second_type,
              target: best_target_for(second_type, reading, candidates),
              parameters: %{}
            }

        _ ->
          runner_up_target(first, reading)
      end

    Enum.uniq_by([first, second], &{&1.action_type, &1.target})
  end

  defp runner_up_target(first, reading) do
    case target_ranking(reading) do
      [_top, {id, _p} | _] -> %SingleAction{first | target: id}
      _ -> %SingleAction{action_type: :other, target: nil, parameters: %{}}
    end
  end

  # The option's actions: the reading itself, plus the deferred action when
  # the option is the primary reading.
  defp option_actions(%SingleAction{} = r, reading) do
    case reading.extraction.actions do
      [primary | deferred]
      when primary.action_type == r.action_type and primary.target == r.target ->
        [r | deferred]

      _ ->
        [r]
    end
  end

  @doc """
  The target candidates by probability, highest first: `[{id | nil, p}]`
  (`nil` is "no target"). Empty when the reply carried no target question.
  """
  @spec target_ranking(map()) :: [{String.t() | nil, float()}]
  def target_ranking(%{target_ranking: ranking}) when is_list(ranking), do: ranking
  def target_ranking(_reading), do: []

  defp best_target_for(type, reading, candidates) do
    kinds =
      case type do
        :move -> [:place, :npc_elsewhere]
        t when t in [:speak, :combat] -> [:npc, :npc_elsewhere]
        t when t in [:buy, :sell, :pickup, :drop, :use_item, :trade] -> [:item]
        :interact -> [:fixture, :item]
        _ -> []
      end

    by_id = Map.new(candidates, &{&1.id, &1.kind})

    reading
    |> target_ranking()
    |> Enum.find_value(fn {id, _p} -> if Map.get(by_id, id) in kinds, do: id end)
  end

  defp phrase(%SingleAction{action_type: :move, target: t}, candidates),
    do: "go to #{target_text(t, candidates) || "somewhere else"}"

  defp phrase(%SingleAction{action_type: :combat, target: t}, candidates),
    do: "attack #{target_text(t, candidates) || "them"}"

  defp phrase(%SingleAction{action_type: :speak, target: t}, candidates),
    do: "talk to #{target_text(t, candidates) || "them"}"

  defp phrase(%SingleAction{action_type: type, target: t}, candidates) do
    case target_text(t, candidates) do
      nil -> @verbs[type] || Atom.to_string(type)
      text -> "#{@verbs[type] || Atom.to_string(type)} #{text}"
    end
  end

  defp target_text(nil, _candidates), do: nil

  defp target_text(id, candidates) do
    case Enum.find(candidates, &(&1.id == id)) do
      %{text: text} ->
        text |> String.split(" — ") |> List.first() |> String.split(" (") |> List.first()

      _ ->
        id
    end
  end

  defp encode_action(action), do: SingleAction.encode(action)
end
