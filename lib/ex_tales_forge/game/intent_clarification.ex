defmodule TalesForge.Game.IntentClarification do
  @moduledoc """
  The act / clarify decision for a Jev intent reading, the candidate
  readings a clarifying question offers, and the question for an attack
  with no clear target.

  The three entry points are `band/2`, `candidates/2` and `combat_target/3`.

  A turn clarifies when the read is unsure or two plausible readings would
  play out differently, acts when it is confident (`>= act_min`), and
  otherwise plays its best guess:

    * Moving goods or coins (`:coin` and `:items` classes) needs
      `act_min`; below it the turn clarifies. Talk and the rest clarify
      below `ask_below` (or Jev's raw confidence below `ask_below_raw`;
      calibration lifts low raw reads a long way) only when the top two
      readings fall in different classes, or for a move or a fight when the
      target itself is unsure.
    * A runner-up reading of another class with a probability of at least
      the `runner_up` threshold (default #{0.25}) is plausible: two
      plausible readings clarify.

  The question itself is voiced by the GM, in character, echoing the
  player's words (`TalesForge.Game.Clarify`); there is no templated
  "Do you want to …?" prompt. See `docs/design-trade-offers.md`.
  """

  alias TalesForge.Game.JevIntent
  alias TalesForge.Game.Schemas.SingleAction

  @default_act_min 0.70
  @default_ask_below 0.45
  @default_ask_below_raw 0.45
  @v2_act_min 0.80
  @v2_ask_below 0.45
  @v2_ask_below_raw 0.30
  @v2_runner_up 0.40
  # Two move/fight targets compete when the runner-up is this close to the top.
  @target_margin 0.25
  # A runner-up reading at least this likely is plausible.
  @default_runner_up 0.25
  # The classes that move goods or coins.
  @goods_classes [:coin, :items]

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
    train: :time,
    rest: :time,
    work: :time,
    equip: :items,
    give: :items
  }

  @verbs %{
    observe: "look around",
    interact: "handle",
    use_item: "use",
    pickup: "pick up",
    drop: "drop",
    buy: "buy",
    ask_price: "ask the price of",
    sell: "sell",
    trade: "trade",
    spend: "pay",
    wait: "wait",
    train: "train",
    rest: "rest",
    work: "work",
    equip: "equip",
    give: "give something to",
    freeform: "do something else",
    other: "do something else"
  }

  @typedoc "The turn's decision for a reading: act on it, play a best guess, or clarify."
  @type decision :: :act | :best_guess | :clarify

  @doc """
  The band thresholds for `version`. `:v1` (the default, `JEV_CLARIFY_V2` off)
  is today's set: `act_min` #{@default_act_min}, `ask_below`
  #{@default_ask_below}, `ask_below_raw` #{@default_ask_below_raw},
  `runner_up` #{@default_runner_up}. `:v2` (`JEV_CLARIFY_V2=on`) is
  #{@v2_act_min} / #{@v2_ask_below} / #{@v2_ask_below_raw} / #{@v2_runner_up}.
  """
  @spec defaults() :: keyword(float())
  @spec defaults(:v1 | :v2) :: keyword(float())
  def defaults(version \\ :v1)

  def defaults(:v1),
    do: [
      act_min: @default_act_min,
      ask_below: @default_ask_below,
      ask_below_raw: @default_ask_below_raw,
      runner_up: @default_runner_up
    ]

  def defaults(:v2),
    do: [
      act_min: @v2_act_min,
      ask_below: @v2_ask_below,
      ask_below_raw: @v2_ask_below_raw,
      runner_up: @v2_runner_up
    ]

  @doc "The consequence class of an action type."
  @spec class(atom()) :: atom()
  def class(action), do: Map.get(@classes, action, :talk)

  @doc """
  The decision for a `t:TalesForge.Game.JevIntent.reading/0`.

  `opts` may set `:act_min` (default #{@default_act_min}), `:ask_below`
  (default #{@default_ask_below}), `:ask_below_raw` (default
  #{@default_ask_below_raw}; `0.0` turns the raw check off) and
  `:runner_up` (default #{@default_runner_up}).

  The turn clarifies when a goods or coin read is below `act_min`, when the
  top two readings play out differently and either the calibrated confidence
  is below `ask_below` or the raw confidence (`reading.raw_confidence`, when
  present) is below `ask_below_raw`, or when a runner-up of another class is
  plausible. Otherwise it acts at a calibrated confidence `>= act_min` and
  plays its best guess in between.

      iex> alias TalesForge.Game.IntentClarification, as: C
      iex> C.band(%{action: :buy, confidence: 0.6, top2: [:buy, :speak], action_probabilities: %{buy: 0.9}})
      :clarify
      iex> C.band(%{action: :speak, confidence: 0.6, top2: [:speak, :observe], action_probabilities: %{speak: 0.6, observe: 0.4}})
      :best_guess
      iex> C.band(%{action: :speak, confidence: 0.9, top2: [:speak, :buy], action_probabilities: %{speak: 0.6, buy: 0.3}})
      :clarify
  """
  @spec band(JevIntent.reading() | map(), keyword()) :: decision()
  def band(reading, opts \\ []) do
    act_min = Keyword.get(opts, :act_min, @default_act_min)
    ask_below = Keyword.get(opts, :ask_below, @default_ask_below)
    ask_below_raw = Keyword.get(opts, :ask_below_raw, @default_ask_below_raw)
    runner_up = Keyword.get(opts, :runner_up, @default_runner_up)
    confidence = reading.confidence || 1.0

    cond do
      moves_goods?(reading) and confidence < act_min ->
        :clarify

      unsure?({confidence, raw_confidence(reading)}, {ask_below, ask_below_raw}) and
          split_class?(reading) ->
        :clarify

      plausible_rival?(reading, runner_up) ->
        :clarify

      confidence >= act_min ->
        :act

      true ->
        :best_guess
    end
  end

  # `{calibrated, raw}` confidence against `{ask_below, ask_below_raw}`.
  defp unsure?({confidence, raw}, {ask_below, ask_below_raw}) do
    confidence < ask_below or (is_number(raw) and raw < ask_below_raw)
  end

  defp raw_confidence(reading), do: Map.get(reading, :raw_confidence)

  # A read that would move goods or coins; a buy that only asks the price
  # (Jev's `ask_price`) moves nothing.
  defp moves_goods?(%{action: action} = reading),
    do: class(action) in @goods_classes and not asks?(reading)

  defp asks?(%{extraction: %{actions: [%SingleAction{parameters: %{"ask" => true}} | _]}}),
    do: true

  defp asks?(_reading), do: false

  # A runner-up action of another class, at least plausible (the top label
  # is the read itself, also when decoding renamed it: `ask_price` is a buy).
  defp plausible_rival?(%{action: action} = reading, runner_up) do
    top = List.first(Map.get(reading, :top2, [])) || action

    reading
    |> Map.get(:action_probabilities, %{})
    |> Enum.any?(fn {other, p} ->
      other not in [action, top] and p >= runner_up and class(other) != class(action)
    end)
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
  The readings a clarifying question offers, as short phrases: the top
  reading with its target, and the runner-up ("buy Mug of Ale", "talk to
  Brenna Holt").
  """
  @spec candidates(JevIntent.reading(), [JevIntent.candidate()]) :: [String.t()]
  def candidates(reading, candidates) do
    reading |> readings(candidates) |> Enum.map(&phrase(&1, candidates)) |> Enum.uniq()
  end

  # The two readings offered: the top action with its target, and either the
  # runner-up action (with the best target of a kind it can take) or, when
  # the actions agree and the target is what is unsure, the runner-up target.
  defp readings(reading, candidates) do
    [first_type | rest] = Enum.uniq(reading.top2 ++ [reading.action])
    primary = List.first(reading.extraction.actions)
    first = %SingleAction{primary | action_type: first_type}
    second = second_reading(first, List.first(rest), {reading, candidates})
    Enum.uniq_by([first, second], &{&1.action_type, &1.target})
  end

  defp second_reading(first, nil, {reading, _candidates}), do: runner_up_target(first, reading)

  defp second_reading(first, type, {reading, candidates}) do
    if class(type) == class(first.action_type) and split_target?(reading),
      do: runner_up_target(first, reading),
      else: %SingleAction{
        action_type: type,
        target: best_target_for(type, reading, candidates),
        parameters: %{}
      }
  end

  defp runner_up_target(first, reading) do
    case target_ranking(reading) do
      [_top, {id, _p} | _] -> %SingleAction{first | target: id}
      _ -> %SingleAction{action_type: :other, target: nil, parameters: %{}}
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
        t when t in [:buy, :ask_price, :sell, :pickup, :drop, :use_item, :trade] -> [:item]
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

  defp phrase(
         %SingleAction{target: nil, parameters: %{"options" => [_ | _] = ids}} = a,
         candidates
       ),
       do:
         "#{@verbs[a.action_type] || a.action_type} #{Enum.map_join(ids, " or ", &target_text(&1, candidates))}"

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

  @doc """
  The question for an attack with no clear target (#281 item 6, QA
  2026-10-14 21:15): "Whom do you attack?", one option for each person here
  (`people` is `[{id, name}]`). Each option attacks that person; the option
  action carries `"target_chosen"` so the combat step takes the target as
  chosen (`TalesForge.Game.Turn.Combat.target/3`).
  """
  @spec combat_target(map(), [{String.t(), String.t()}], String.t()) :: map()
  def combat_target(reading, people, raw_action) do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    primary = List.first(reading.extraction.actions) || %SingleAction{action_type: :combat}
    params = primary.parameters || %{}

    options =
      Enum.map(people, fn {npc_id, _name} ->
        %SingleAction{
          action_type: :combat,
          target: npc_id,
          parameters: Map.put(params, "target_chosen", true)
        }
      end)

    %{
      "clarification_id" => id,
      "source" => "combat_target",
      "question" => "Whom do you attack? #{Enum.map_join(people, ", or ", &elem(&1, 1))}?",
      "options" =>
        people
        |> Enum.with_index()
        |> Enum.map(fn {{_npc_id, name}, idx} ->
          %{
            "id" => "option_#{idx}",
            "label" => "combat",
            "description" => "Attack #{name}",
            "action_index" => idx
          }
        end),
      "option_actions" => Enum.map(options, &[encode_action(&1)]),
      "allow_free_text" => true,
      "overall_intent" => reading.extraction.overall_intent,
      "confidence" => reading.confidence,
      "raw_action" => raw_action,
      "actions" => Enum.map(reading.extraction.actions, &encode_action/1)
    }
  end

  defp encode_action(action), do: SingleAction.encode(action)
end
