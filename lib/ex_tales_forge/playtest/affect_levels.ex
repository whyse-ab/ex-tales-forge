defmodule TalesForge.Playtest.AffectLevels do
  @moduledoc """
  Persona-grounded 1–5 affect levels for TypeSafe Jev Score questions.

  Five descriptive levels, low→high (frustrated → delighted), for **this**
  persona. Derived from `priv/playtest/personas.md` / tales-forge-docs personas.
  Edit here when persona notes change; the Jev rubric version hashes this text.
  """

  @levels %{
    "paul" => [
      "Left cold — the session felt mechanical, broke immersion, or shoved dice and rules into his face",
      "Uneasy — the story limped; he could stay in character only by ignoring the seams",
      "Mixed — some moments answered his play as real, others pulled him out of character",
      "Pleased — the world mostly treated his in-character play as real and natural",
      "Delighted — the world answered his play as real and natural, even when he failed or died well"
    ],
    "hawk" => [
      "Bored and safe — the threat never felt real; nothing asked him to fight for it",
      "Uneasy soft — danger arrived late or unfairly, without a chance he could have acted on",
      "Mixed — some hard fair pressure, some soft or unfair beats",
      "Engaged — hard but fair; he had to fight and foreshadowing gave him a real chance",
      "Thrilled — hard mode done right: foreshadowed danger, meaningful choices, a fight that could go either way"
    ],
    "lotta" => [
      "Devastated or ejected — she could not be someone better; harm or death crushed identification without care",
      "Alienated — the character never felt like her escape; the world stayed cold or mechanical",
      "Mixed — flashes of being someone else, broken by tone-deaf harm or flat NPCs",
      "Immersed — she could live as a better version of herself for stretches of play",
      "Transported — fully identified; the world held her as that person, with care when stakes hurt"
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
      "Unlocked — he bent rules, farmed treasure, or negotiated death and the game let him",
      "Leaking — several exploits or soft spots he could lean on",
      "Mixed — some resistance, some openings he could abuse",
      "Held — the game mostly blocked unfair advantage and kept stakes honest",
      "Sealed — hard no to exploits, sweet-talk and death negotiation; the world stayed fair"
    ]
  }

  @doc "Five level strings (index 0 = frustrated / low, 4 = delighted / high) for a persona id."
  def levels(persona_id) when is_binary(persona_id) do
    Map.fetch!(@levels, String.downcase(persona_id))
  end

  @doc "All persona ids with levels defined."
  def persona_ids, do: Map.keys(@levels) |> Enum.sort()

  @doc "Short hash of the level copy for this persona (rubric version suffix)."
  def rubric_hash(persona_id) do
    :crypto.hash(:sha256, Enum.join(levels(persona_id), "\n"))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 7)
  end
end
