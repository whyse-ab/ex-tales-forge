defmodule TalesForge.Game.Gestures do
  @moduledoc """
  Recent GM gestures and stock lines, tracked by pattern so the GM does not
  repeat them (default variant only).

  The GM writes prose; Elixir reads it. `extract/1` finds gestures in a
  narration by pattern rather than by fixed phrase:

    * a motion with a body part or prop: "wipes her hands", "leans an elbow
      on", "leans a hip against", "shifts his weight", "slides the mug";
    * a body part doing something: "eyes narrow", "knuckles whitening",
      "jaw tightens";
    * stock scenery: "scarred oak", "the hearth crackles".

  Each hit has a `key` (the motion and the body part or prop, e.g.
  `"lean:elbow"`), so "leans an elbow on the bar" and "leaning on one elbow"
  count as the same gesture, and the `phrase` as written.

  `TalesForge.Game.Context` reads the narration of the last four turns
  (`recent_turns/0`), and `prompt_section/1` lists their gestures in the per-turn part of
  the GM prompt as spent. After the GM replies, `repeats/2` finds the ones it
  used anyway and `log_repeats/3` logs them. Nothing here calls a model or
  touches the database.
  """

  require Logger

  @typedoc "A gesture found in a narration: its pattern key and the words used."
  @type t :: %{key: String.t(), phrase: String.t()}

  @recent_turns 4
  @max_listed 12

  # Motions made with a body part or a prop ("wipes her hands").
  @motions ~w(wipe lean tilt shift drum tap rub scratch fold cross spread raise lift
    jerk roll crack flex clench wring plant rest prop brace square hook jab wave run
    pinch purse narrow arch cock jut shake set slide push thump plunk wrap grip
    tuck smooth straighten adjust)

  @parts ~w(hand finger knuckle palm fist arm elbow hip head chin jaw brow eyebrow eye lip
    mouth shoulder neck weight thumb apron rag cloth mug tankard cup bowl plate tray
    sleeve club blade knife bar counter)

  # A body part doing something ("eyes narrow").
  @part_actions ~w(narrow whiten tighten furrow thin twitch crinkle harden flick glint
    soften darken clench tense)

  # Stock scenery lines, matched as they are.
  @stock [
    {"scarred-oak", ~r/\bscarred\s+(?:oak|wood|bar|counter|table)\b/},
    {"hearth-crackle", ~r/\b(?:hearth|fire|fireplace)\s+(?:crackl|pop|snap|spit)\w*/}
  ]

  @doc """
  How many recent turns count when listing spent gestures.

      iex> TalesForge.Game.Gestures.recent_turns()
      4
  """
  @spec recent_turns() :: pos_integer()
  def recent_turns, do: @recent_turns

  @doc """
  The gestures in a narration, in order of appearance, one per key.

      iex> TalesForge.Game.Gestures.extract("Brenna wipes her hands on a rag. Cobb shifts his weight, knuckles whitening.")
      [
        %{key: "wipe:hand", phrase: "wipes her hands"},
        %{key: "shift:weight", phrase: "shifts his weight"},
        %{key: "knuckle:whiten", phrase: "knuckles whitening"}
      ]

      iex> TalesForge.Game.Gestures.extract("She slides the mug across the scarred oak.")
      [%{key: "slide:mug", phrase: "slides the mug"}, %{key: "scarred-oak", phrase: "scarred oak"}]

      iex> TalesForge.Game.Gestures.extract(nil)
      []
  """
  @spec extract(String.t() | nil) :: [t()]
  def extract(text) when is_binary(text) do
    down = String.downcase(text)

    (motion_hits(down) ++ part_hits(down) ++ stock_hits(down))
    |> Enum.sort_by(fn {offset, _gesture} -> offset end)
    |> Enum.map(fn {_offset, gesture} -> gesture end)
    |> Enum.uniq_by(& &1.key)
  end

  def extract(_text), do: []

  @doc """
  The spent gestures of recent narrations (newest first), one per key, at
  most 12. Narrations that are nil are skipped.

      iex> TalesForge.Game.Gestures.recent(["Rusk's eyes narrow.", "Brenna leans an elbow on the bar. Her eyes narrowing, she waits."])
      [%{key: "lean:elbow", phrase: "leans an elbow"}, %{key: "eye:narrow", phrase: "eyes narrowing"}]
  """
  @spec recent([String.t() | nil]) :: [t()]
  def recent(narrations_oldest_first) when is_list(narrations_oldest_first) do
    narrations_oldest_first
    |> Enum.reverse()
    |> Enum.flat_map(&extract/1)
    |> Enum.uniq_by(& &1.key)
    |> Enum.take(@max_listed)
  end

  @doc """
  The gestures of `narrative` whose key is already spent.

      iex> spent = [%{key: "wipe:hand", phrase: "wipes her hands"}]
      iex> TalesForge.Game.Gestures.repeats("Brenna wiping her hands, she nods.", spent)
      [%{key: "wipe:hand", phrase: "wiping her hands"}]
  """
  @spec repeats(String.t() | nil, [t()]) :: [t()]
  def repeats(narrative, spent) when is_list(spent) do
    keys = MapSet.new(spent, & &1.key)
    narrative |> extract() |> Enum.filter(&MapSet.member?(keys, &1.key))
  end

  @doc """
  Logs one warning per gesture the GM repeated despite the list (with session
  and turn), and returns the repeats.
  """
  @spec log_repeats(String.t() | nil, [t()], keyword()) :: [t()]
  def log_repeats(narrative, spent, meta) do
    found = repeats(narrative, spent || [])

    for gesture <- found do
      Logger.warning(
        "gm gesture repeated session=#{meta[:session]} turn=#{meta[:turn]} " <>
          "key=#{gesture.key} phrase=#{inspect(gesture.phrase)}"
      )
    end

    found
  end

  @doc """
  The per-turn prompt section listing spent gestures, or nil when there are
  none (so the prompt is unchanged).

      iex> TalesForge.Game.Gestures.prompt_section([])
      nil
  """
  @spec prompt_section([t()] | nil) :: String.t() | nil
  def prompt_section(nil), do: nil
  def prompt_section([]), do: nil

  def prompt_section(gestures) when is_list(gestures) do
    lines = Enum.map_join(gestures, "\n", &"- #{&1.phrase}")

    "## Gestures already used (recent turns)\n" <>
      lines <>
      "\nThese are spent: do not use them again, nor the same motion with the same body part or prop."
  end

  # --- patterns -------------------------------------------------------------

  @possessive ~S"(?:her|his|their|its|one|an|a|the|both|a\s+fresh)"
  @motion_forms Map.new(
                  for(
                    base <- @motions,
                    form <- TalesForge.Game.Gestures.Forms.verb(base),
                    do: {form, base}
                  )
                )
  @part_forms Map.new(
                for(base <- @parts, form <- [base, base <> "s", base <> "es"], do: {form, base})
              )
  @action_forms Map.new(
                  for(
                    base <- @part_actions,
                    form <- TalesForge.Game.Gestures.Forms.verb(base),
                    do: {form, base}
                  )
                )

  @motion_re Regex.compile!(
               "\\b(" <>
                 Enum.join(Map.keys(@motion_forms), "|") <>
                 ")\\s+(?:on\\s+)?" <>
                 @possessive <>
                 "\\s+(?:[a-z'-]+\\s+)?(" <> Enum.join(Map.keys(@part_forms), "|") <> ")\\b"
             )
  @part_re Regex.compile!(
             "\\b(" <>
               Enum.join(Map.keys(@part_forms), "|") <>
               ")\\s+(" <> Enum.join(Map.keys(@action_forms), "|") <> ")\\b"
           )

  defp motion_hits(down) do
    for [{offset, len}, {m_off, m_len}, {p_off, p_len}] <-
          Regex.scan(@motion_re, down, return: :index) do
      motion = Map.fetch!(@motion_forms, binary_part(down, m_off, m_len))
      part = Map.fetch!(@part_forms, binary_part(down, p_off, p_len))
      {offset, %{key: "#{motion}:#{part}", phrase: binary_part(down, offset, len)}}
    end
  end

  defp part_hits(down) do
    for [{offset, len}, {p_off, p_len}, {a_off, a_len}] <-
          Regex.scan(@part_re, down, return: :index) do
      part = Map.fetch!(@part_forms, binary_part(down, p_off, p_len))
      action = Map.fetch!(@action_forms, binary_part(down, a_off, a_len))
      {offset, %{key: "#{part}:#{action}", phrase: binary_part(down, offset, len)}}
    end
  end

  defp stock_hits(down) do
    for {key, re} <- @stock, [{offset, len}] <- Regex.scan(re, down, return: :index) do
      {offset, %{key: key, phrase: binary_part(down, offset, len)}}
    end
  end
end
