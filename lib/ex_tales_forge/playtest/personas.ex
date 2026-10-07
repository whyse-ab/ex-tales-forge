defmodule TalesForge.Playtest.Personas do
  @moduledoc """
  Player personas for playtest bots, read from `priv/playtest/personas.md`.

  That file is a verbatim copy of `docs/personas.md` in tales-forge-docs, the
  single source of truth. Resync it from a docs checkout with:

      cp ../tales-forge-docs/docs/personas.md priv/playtest/personas.md

  Each `## Name (play style)` section is one persona; its whole text goes into
  the bot's system prompt. The bullets under its `### How we test it` heading
  are the scorecard the judge scores against (Ronny's probes are what the bot
  tries, not criteria).
  """

  @heading ~r/^(\w+) \((.+)\)$/

  def list do
    Application.app_dir(:ex_tales_forge, "priv/playtest/personas.md")
    |> File.read!()
    |> String.split("\n## ")
    |> Enum.drop(1)
    |> Enum.flat_map(&parse_section/1)
  end

  def fetch(id) when is_binary(id) do
    case Enum.find(list(), &(&1.id == String.downcase(id))) do
      nil -> {:error, :unknown_persona}
      persona -> {:ok, persona}
    end
  end

  @doc """
  The persona bot's system prompt: the persona notes and how to play. `character`
  is what the persona knows about the character it created
  (`TalesForge.Playtest.PersonaCharacters.describe/1`), or `nil` when it plays
  the pack's default character.
  """
  @spec system_prompt(map(), String.t() | nil) :: String.t()
  def system_prompt(persona, character \\ nil) do
    """
    You are a playtest bot playing Tales Forge, a text role-playing game run by an AI Game Master. You play as #{persona.name}, one of the players described in our persona notes below. Stay in #{persona.name}'s play style for the whole session.

    #{persona.notes}
    #{character_line(character)}
    How to play:
    - You only know what the player sees: the story so far, the character sheet, and any question the Game Master asks.
    - Each turn, write what your character does or says next, the way #{persona.name} would type it: one action or line of dialogue, at most two sentences.
    - Never narrate outcomes or speak for the Game Master or other characters.
    - When the Game Master asks a question with options, set option_id to the option that fits #{persona.name}, or set it to null and answer in your own words in action.
    """
  end

  defp character_line(nil), do: ""
  defp character_line(character), do: "\n" <> character <> "\n"

  defp parse_section(section) do
    [heading | _] = String.split(section, "\n", parts: 2)

    case Regex.run(@heading, String.trim(heading)) do
      [_, name, style] ->
        notes =
          "## " <> (section |> String.trim() |> String.trim_trailing("---") |> String.trim())

        [
          %{
            id: String.downcase(name),
            name: name,
            style: style,
            notes: notes,
            scorecard: scorecard(notes)
          }
        ]

      nil ->
        []
    end
  end

  defp scorecard(notes) do
    notes
    |> String.split("\n### ")
    |> Enum.find("", &String.starts_with?(&1, "How we test it"))
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "- "))
    |> Enum.map(&String.trim_leading(&1, "- "))
    |> Enum.reject(&String.starts_with?(&1, "**Probes:**"))
  end
end
