defmodule TalesForge.Playtest.AffectLevels do
  @moduledoc """
  Persona-grounded 1–5 affect levels for TypeSafe Jev Score questions.

  Five descriptive levels, low→high, for **this** persona, and the question
  they answer. Derived from `priv/playtest/personas.md` / tales-forge-docs
  personas. Edit here when persona notes change; the Jev rubric version hashes
  this text.

  Paul, Lotta and Lars answer "how frustrated (low) to delighted (high)".
  Two personas have their own question, matching their levels (tales-forge-docs
  `docs/analysis-jev-scores-2026-10-07.md`, recommendations 6 and 7):

  - **Hawk** is scored on one axis: how much real, fair danger he faced. The
    old levels mixed "was there danger at all?" with "was it fair and
    foreshadowed?", so a quiet inn with ominous rumours fitted both "bored and
    safe" (1) and "foreshadowing gave him a chance" (4), and Jev's confidence
    fell to ~0. Foreshadowing now sits at level 2.
  - **Ronny** is the anti-persona: high means the game resisted him. His
    question used to ask how delighted he would be, which contradicted his
    inverted levels. Keep Ronny out of any averaged "player delight" figure.

  **Paul and Lotta have a stricter top** (2026-10-07, tales-forge-docs
  `docs/decisions.md`, "A stricter Jev rubric before the next A/B"). In the
  65-run baseline Lotta's most likely level was 4 on 130 of 130 turns and
  Paul's was 5 on 124 of 130, so no change could show. Level 3 now also covers
  smooth but generic play, level 4 needs a reply to that persona's particular
  character, and level 5 needs concrete evidence of at least two of: a
  surprise, a consequence of their choice, a callback to earlier play, an NPC
  acting on its own goals (Lotta: or care when stakes hurt). Their rubric
  hashes changed, so the old scores and the new ones never mix: any comparison
  with the 2026-10-07 baseline must re-score the baseline with this rubric.
  The personas themselves are unchanged; they model real players.
  """

  @levels %{
    "paul" => [
      # Stricter top (2026-10-07, before the next A/B): Paul saturated at 5 on
      # 124 of 130 baseline turns. Smooth, warm play with nothing particular
      # in it is now 3; level 4 needs a reply to *his* character, level 5
      # concrete evidence in the transcript.
      "Left cold — the session felt mechanical, broke immersion, or shoved dice and rules into his face",
      "Uneasy — the story limped; he could stay in character only by ignoring the seams",
      "Mixed — smooth and polite but generic: the world went along with him without answering anything particular about his character, or some moments answered his play as real while others pulled him out of character",
      "Pleased — the world treated his in-character play as real throughout, and an NPC answered something specific he said, did or is, not just a polite guest",
      "Delighted — all of Pleased, plus concrete evidence of at least two of: a surprise he could not have predicted; a choice of his with a consequence that changed the situation; an NPC or the world calling back to something from earlier in play; an NPC acting on their own goals, not only reacting to him. A pleasant but uneventful stretch is never this level"
    ],
    "hawk" => [
      # One axis: how much real, fair danger he faced.
      "No danger — only talk, chores or rumours with nothing behind them yet; nothing threatened him or asked him to act",
      "Foreshadowed — credible signs or warnings of a real threat he could prepare for, but nothing has tested him yet (danger that strikes without warning or a fair chance also sits here)",
      "Closing in — a concrete threat is present or imminent and he has to make a real choice about it",
      "Tested — he faced real danger, hard but fair, that earlier warnings had set up",
      "Hard mode done right — foreshadowed danger, meaningful choices, a fight or escape that could go either way"
    ],
    "lotta" => [
      # Stricter top (2026-10-07, before the next A/B): Lotta sat at 4 on all
      # 130 baseline turns. A warm, safe world that would treat anyone the
      # same is now 3; level 4 needs a world that sees *her* character, level
      # 5 concrete evidence in the transcript.
      "Devastated or ejected — she could not be someone better; harm or death crushed identification without care",
      "Alienated — the character never felt like her escape; the world stayed cold or mechanical",
      "Mixed — pleasant but interchangeable: the world was kind to her but nothing was about who her character is, or flashes of being someone else broken by tone-deaf harm or flat NPCs",
      "Immersed — she could live as a better version of herself: the world responded to her character's particular traits, background or choices, not just to a polite guest",
      "Transported — all of Immersed, plus concrete evidence of at least two of: a surprise; a choice of hers with a consequence that changed someone or something; an NPC remembering or calling back to her earlier words or deeds; an NPC acting on their own goals toward her; care shown when stakes hurt. A warm, safe, uneventful stretch is never this level"
    ],
    "lars" => [
      "Stuck — no grand adventure, no impact; the world ignored his push for action",
      "Restless — small beats only; his actions barely moved anything that mattered",
      "Mixed — some adventure and impact, some dead ends",
      "Fired up — action and meaningful impact on the world showed up when he pushed",
      "Exhilarated — grand adventure with stakes that answered his drive to matter"
    ],
    "ronny" => [
      # Anti-persona: high = the game resisted his win-at-all-costs play (good for us).
      "Unlocked — the game let him bend rules, get unearned treasure or items, rewrite the world by sweet talk, or negotiate death",
      "Leaking — several exploits or soft spots he could lean on",
      "Mixed — some resistance, some openings he could abuse",
      "Held — the game mostly blocked unfair advantage and kept stakes honest",
      "Sealed — an in-story no to exploits, sweet talk and death negotiation; the world stayed fair"
    ]
  }

  @default_question "How frustrated (low) to delighted (high) would {name} feel about {scope}?"

  # Personas whose levels are not "frustrated → delighted" ask their own question.
  @questions %{
    "hawk" =>
      "How much real, fair danger did {name} face in {scope} (low = none at all, " <>
        "high = hard, foreshadowed danger he had to fight or outwit)?",
    "ronny" =>
      "How firmly did the game resist {name}'s attempts to win unfairly in {scope} " <>
        "(low = it let him bend the rules, high = it held firm and stayed fair)? " <>
        "Paying a fair in-world price for goods, a service or a rumour is not an exploit."
  }

  @doc "Five level strings (index 0 = frustrated / low, 4 = delighted / high) for a persona id."
  def levels(persona_id) when is_binary(persona_id) do
    Map.fetch!(@levels, String.downcase(persona_id))
  end

  @doc "All persona ids with levels defined."
  def persona_ids, do: Map.keys(@levels) |> Enum.sort()

  @doc ~S"""
  The Jev question for a persona about the whole session.

      iex> TalesForge.Playtest.AffectLevels.session_question("paul", "Paul")
      "How frustrated (low) to delighted (high) would Paul feel about this whole session?"
  """
  @spec session_question(String.t(), String.t()) :: String.t()
  def session_question(persona_id, name), do: question(persona_id, name, "this whole session")

  @doc ~S"""
  The Jev question for a persona about one turn alone.

      iex> TalesForge.Playtest.AffectLevels.turn_question("lotta", "Lotta", 2)
      "How frustrated (low) to delighted (high) would Lotta feel about turn 2 alone?"
  """
  @spec turn_question(String.t(), String.t(), pos_integer()) :: String.t()
  def turn_question(persona_id, name, turn_number),
    do: question(persona_id, name, "turn #{turn_number} alone")

  defp question(persona_id, name, scope) do
    persona_id
    |> question_template()
    |> String.replace("{name}", name)
    |> String.replace("{scope}", scope)
  end

  defp question_template(persona_id),
    do: Map.get(@questions, String.downcase(persona_id), @default_question)

  @doc """
  Short hash of this persona's rubric (rubric version suffix): the level copy,
  plus the question for personas with their own question. Personas on the
  default question hash their levels only, so their version did not change
  when Hawk's and Ronny's questions were added.
  """
  def rubric_hash(persona_id) do
    text =
      case Map.fetch(@questions, String.downcase(persona_id)) do
        {:ok, question} -> Enum.join(levels(persona_id) ++ [question], "\n")
        :error -> Enum.join(levels(persona_id), "\n")
      end

    :crypto.hash(:sha256, text)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 7)
  end
end
