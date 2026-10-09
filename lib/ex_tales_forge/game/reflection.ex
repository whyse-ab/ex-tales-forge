defmodule TalesForge.Game.Reflection do
  @moduledoc """
  Which skills a player's words reflect on, practise or study (decision
  2026-10-09, skill growth from level 10, tales-forge-docs `docs/decisions.md`).

  From `reflection_level` (10) a skill only grows on a long rest if the
  character reflected on it, practised or studied it, or trained it since the
  last long rest (`TalesForge.Game.Progression.resolve_rest/3`). This module is
  the simple Elixir rule for the words: a reflection verb ("reflect on",
  "practise", "study", "go over", "think back on", "meditate on", "drill",
  "rehearse", "spar") plus a word that names the skill ("sword", "haggling",
  "lockpicking"). Both must be in the text; a skill name alone, or a verb with
  no skill, counts for nothing.

  `TalesForge.Game.TurnProcessor` keeps the skills found, plus a skill trained
  with a trainer, in the character's `"reflecting"` list until the next long
  rest, so reflecting the turn before sleeping counts as well.
  """

  @verbs ~r/\b(reflect\w*|practi[cs]\w*|stud(?:y|ies|ying|ied)|go(?:es|ing)? over|went over|think(?:s|ing)? (?:back )?(?:on|over|about)|thought (?:back )?(?:on|over|about)|meditat\w*|drill\w*|rehears\w*|spar(?:s|ring)?|mull\w* over|ponder\w*)\b/i

  # Words that name each skill in play. Literal skill names, as in
  # TalesForge.Game.Mechanics.skill_stat_map/0.
  @skill_words [
    {"melee_combat",
     ~r/\b(melee|sword\w*|blade\w*|axe|mace|spear\w*|swordplay|fencing|fight\w*|footwork)\b/i},
    {"ranged_combat", ~r/\b(ranged|bow\w*|archery|arrow\w*|shoot\w*|aim|throwing)\b/i},
    {"unarmed_combat", ~r/\b(unarmed|fists?|brawl\w*|wrestl\w*|grappl\w*|punch\w*)\b/i},
    {"tactics", ~r/\b(tactic\w*|strateg\w*)\b/i},
    {"dodge", ~r/\b(dodg\w*|evasion|evading)\b/i},
    {"stealth", ~r/\b(stealth|sneak\w*|hiding)\b/i},
    {"lockpicking", ~r/\b(lock\s?pick\w*|locks)\b/i},
    {"climbing", ~r/\b(climb\w*)\b/i},
    {"persuasion", ~r/\b(persua\w*|haggl\w*|bargain\w*|negotiat\w*)\b/i},
    {"deception", ~r/\b(decepti\w*|deceiv\w*|lies|lying|bluff\w*)\b/i},
    {"intimidation", ~r/\b(intimidat\w*|threat\w*)\b/i},
    {"insight", ~r/\b(insight|reading people)\b/i},
    {"etiquette", ~r/\b(etiquette|manners)\b/i},
    {"survival", ~r/\b(survival|woodcraft)\b/i},
    {"tracking", ~r/\b(track\w*)\b/i},
    {"history", ~r/\b(history|lore)\b/i},
    {"arcana", ~r/\b(arcan\w*|magic|spells?)\b/i}
  ]

  @doc """
  The skills the text reflects on, practises or studies, sorted; `[]` when it
  has no reflection verb or names no skill.

      iex> TalesForge.Game.Reflection.skills("Before I sleep I go over the day's swordplay in my head")
      ["melee_combat"]
      iex> TalesForge.Game.Reflection.skills("I practise my haggling and think back on the lies Rusk told")
      ["deception", "persuasion"]
      iex> TalesForge.Game.Reflection.skills("I go to sleep")
      []
      iex> TalesForge.Game.Reflection.skills("I sharpen my sword")
      []
  """
  @spec skills(String.t() | nil) :: [String.t()]
  def skills(text) when is_binary(text) do
    if Regex.match?(@verbs, text) do
      @skill_words
      |> Enum.filter(fn {_skill, pattern} -> Regex.match?(pattern, text) end)
      |> Enum.map(fn {skill, _} -> skill end)
      |> Enum.sort()
    else
      []
    end
  end

  def skills(_text), do: []

  @doc "The skills `skill_words` covers (for the parity test with `TalesForge.Game.Mechanics`)."
  @spec covered_skills() :: [String.t()]
  def covered_skills, do: @skill_words |> Enum.map(&elem(&1, 0)) |> Enum.sort()
end
