defmodule TalesForge.Characters.Levers do
  @moduledoc """
  The behaviour levers every character carries: OCEAN (five traits, 0–10), a
  Maslow level and up to three concerns.

  `validate!/2` checks authored pack data and raises `ArgumentError` naming the
  file, so a bad pack fails at load time instead of mid-session.
  """

  @maslow_levels ~w(physiological safety belonging esteem self_actualisation)
  @ocean_traits ~w(openness conscientiousness extraversion agreeableness neuroticism)
  @max_concerns 3
  @lever_keys ~w(ocean maslow concerns)

  @doc "Maslow levels, lowest need first."
  def maslow_levels, do: @maslow_levels

  @doc "The five OCEAN trait names."
  def ocean_traits, do: @ocean_traits

  @doc "Most concerns a character carries at once."
  def max_concerns, do: @max_concerns

  @doc "Keys a pack character file holds next to the sheet (stripped from the sheet)."
  def lever_keys, do: @lever_keys

  @doc """
  Validates the levers of an authored character or NPC definition.

  Requires `maslow` (a level) and `concerns` (a list of at most three maps, each
  with a non-empty `text` and an optional integer `priority` 1–10). OCEAN comes
  from `ocean` or, for NPCs, `motivations.personality_traits`; when present each
  trait must be a known name with an integer 0–10.
  """
  def validate!(definition, source) when is_map(definition) do
    validate_maslow!(definition["maslow"], source)
    validate_concerns!(definition["concerns"], source)
    validate_ocean!(ocean_source(definition), source)
    :ok
  end

  @doc "The authored OCEAN map: `ocean`, else the NPC `motivations.personality_traits`."
  def ocean_source(definition) when is_map(definition) do
    definition["ocean"] || get_in(definition, ["motivations", "personality_traits"]) || %{}
  end

  defp validate_maslow!(level, _source) when level in @maslow_levels, do: :ok

  defp validate_maslow!(level, source) do
    fail!(
      source,
      "maslow must be one of #{Enum.join(@maslow_levels, ", ")}, got #{inspect(level)}"
    )
  end

  defp validate_concerns!(concerns, source) when is_list(concerns) do
    if length(concerns) > @max_concerns do
      fail!(source, "at most #{@max_concerns} concerns, got #{length(concerns)}")
    end

    Enum.each(concerns, &validate_concern!(&1, source))
  end

  defp validate_concerns!(other, source),
    do: fail!(source, "concerns must be a list, got #{inspect(other)}")

  defp validate_concern!(%{"text" => text} = concern, source)
       when is_binary(text) and text != "" do
    case Map.get(concern, "priority") do
      nil -> :ok
      p when is_integer(p) and p in 1..10 -> :ok
      p -> fail!(source, "concern priority must be an integer 1–10, got #{inspect(p)}")
    end
  end

  defp validate_concern!(concern, source),
    do: fail!(source, "each concern needs a non-empty text, got #{inspect(concern)}")

  defp validate_ocean!(ocean, source) when is_map(ocean) do
    Enum.each(ocean, fn
      {trait, value} when trait in @ocean_traits and is_integer(value) and value in 0..10 ->
        :ok

      {trait, value} ->
        fail!(
          source,
          "OCEAN #{inspect(trait)} must be a known trait with 0–10, got #{inspect(value)}"
        )
    end)
  end

  defp validate_ocean!(other, source),
    do: fail!(source, "ocean must be a map, got #{inspect(other)}")

  defp fail!(source, message), do: raise(ArgumentError, "#{source}: #{message}")
end
