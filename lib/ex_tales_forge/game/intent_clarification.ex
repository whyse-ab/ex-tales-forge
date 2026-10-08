defmodule TalesForge.Game.IntentClarification do
  @moduledoc """
  The act / ask decision for a Jev intent reading, and the templated question
  shown when the game asks.

  A turn acts when the read is confident (`>= act_min`), asks only when it is
  unsure (`< ask_below`) **and** the two most likely readings fall in different
  consequence classes (talk is cheap to get wrong; a fight, a move, or spending
  coin is not), and otherwise plays its best guess. At most one question per
  turn. See `tales-forge-docs/docs/design-jev-intent.md` §4.

  This module is not wired into live turns; it is the behaviour `mix intent.eval`
  measures. The question payload matches `TalesForge.Game.Intent.build_clarification/2`
  so it can drop in later unchanged.
  """

  alias TalesForge.Game.JevIntent

  @default_act_min 0.70
  @default_ask_below 0.45

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
  # kinds of consequence (so a wrong guess is worth a question).
  defp split_class?(%{top2: [a, b | _]}), do: class(a) != class(b)
  defp split_class?(_reading), do: false

  @doc """
  The clarification payload for a reading over `candidates`: a templated
  question offering the top readings, matching the shape
  `TalesForge.Game.Intent.build_clarification/2` returns.
  """
  @spec build(JevIntent.reading(), [JevIntent.candidate()]) :: map()
  def build(reading, candidates) do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    options = options(reading, candidates)

    %{
      "clarification_id" => id,
      "question" => question(reading, candidates),
      "options" => options,
      "allow_free_text" => true,
      "overall_intent" => reading.extraction.overall_intent,
      "confidence" => reading.confidence,
      "raw_action" => reading.extraction.overall_intent,
      "actions" => Enum.map(reading.extraction.actions, &encode_action/1)
    }
  end

  defp question(reading, candidates) do
    [first, second | _] = reading.top2 ++ [:other, :other]

    "Do you want to #{phrase(first, reading, candidates)}, or #{phrase(second, reading, candidates)}?"
  end

  defp options(reading, candidates) do
    reading.top2
    |> Enum.with_index()
    |> Enum.map(fn {action, idx} ->
      %{
        "id" => "option_#{idx}",
        "label" => Atom.to_string(action),
        "description" => phrase(action, reading, candidates),
        "action_index" => idx
      }
    end)
  end

  defp phrase(:move, reading, candidates) do
    "go to #{target_text(reading.target, candidates) || "somewhere"}"
  end

  defp phrase(:combat, reading, candidates) do
    "attack #{target_text(reading.target, candidates) || "them"}"
  end

  defp phrase(:speak, reading, candidates) do
    "talk to #{target_text(reading.target, candidates) || "them"}"
  end

  defp phrase(action, _reading, _candidates), do: Atom.to_string(action)

  defp target_text(nil, _candidates), do: nil

  defp target_text(id, candidates) do
    case Enum.find(candidates, &(&1.id == id)) do
      %{text: text} ->
        text |> String.split(" — ") |> List.first() |> String.split(" (") |> List.first()

      _ ->
        id
    end
  end

  defp encode_action(action), do: TalesForge.Game.Schemas.SingleAction.encode(action)
end
