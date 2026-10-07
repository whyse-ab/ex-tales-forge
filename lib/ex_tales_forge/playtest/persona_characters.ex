defmodule TalesForge.Playtest.PersonaCharacters do
  @moduledoc """
  The character each playtest persona creates and plays, instead of the pack's
  default character (Elara).

  The picks (name, race, class, base stats, race bonus and a one-line concept)
  are data in `priv/playtest/characters.json`, derived from the persona notes.
  The reasoning is in `docs/playtest-persona-characters.md` in tales-forge-docs.
  They are built through `TalesForge.CharacterCreation`, the same functions the
  creation screen uses, with a fixed seed per persona, so every run of a persona
  plays the same character (same derived OCEAN, Maslow level, concerns and coins).
  """

  alias TalesForge.CharacterCreation

  @typedoc "One persona's pick, as in `characters.json`."
  @type pick :: %{required(String.t()) => term()}

  @doc "Every persona's pick, keyed by persona id."
  @spec picks() :: %{optional(String.t()) => pick()}
  def picks do
    Application.app_dir(:ex_tales_forge, "priv/playtest/characters.json")
    |> File.read!()
    |> Jason.decode!()
    |> Map.reject(fn {id, _} -> String.starts_with?(id, "_") end)
  end

  @doc "The pick for `persona_id`, or `nil` if it has none."
  @spec pick(String.t()) :: pick() | nil
  def pick(persona_id), do: Map.get(picks(), persona_id)

  @doc """
  Creates `persona_id`'s character for `adventure_id` with
  `TalesForge.CharacterCreation` and returns it in the shape of a pack
  character file, ready for `TalesForge.GameSessions.create_session/1`.

  `{:error, :no_pick}` if the persona has no pick; a pick the creation rules
  reject returns their error.
  """
  @spec build(String.t(), String.t()) ::
          {:ok, map()}
          | {:error, :no_pick | CharacterCreation.error() | [CharacterCreation.error()]}
  def build(persona_id, adventure_id) do
    case pick(persona_id) do
      nil -> {:error, :no_pick}
      pick -> create(pick, persona_id, adventure_id)
    end
  end

  @doc """
  What the persona knows about the character it made, for its system prompt:
  name, race, class and concept.

      iex> TalesForge.Playtest.PersonaCharacters.describe(%{"name" => "Ann", "race" => "half_elf", "class" => "cleric", "concept" => "A healer."})
      "You created this character yourself: Ann, a half-elf cleric. A healer."
  """
  @spec describe(pick()) :: String.t()
  def describe(%{"name" => name, "race" => race, "class" => class} = pick) do
    race = String.replace(race, "_", "-")
    article = if String.first(race) in ~w(a e i o u), do: "an", else: "a"

    [
      "You created this character yourself: #{name}, #{article} #{race} #{class}.",
      pick["concept"]
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp create(pick, persona_id, adventure_id) do
    draft = CharacterCreation.new(adventure_id, seed_key: "playtest-" <> persona_id)

    with {:ok, draft} <- CharacterCreation.choose_race(draft, pick["race"]),
         {:ok, draft} <- CharacterCreation.choose_class(draft, pick["class"]),
         {:ok, draft} <- set_stats(draft, pick["base_stats"]),
         {:ok, draft} <- race_bonus(draft, pick["race_bonus"]),
         {:ok, draft} <- CharacterCreation.set_name(draft, pick["name"]) do
      CharacterCreation.finalize(draft)
    end
  end

  defp set_stats(draft, stats) do
    Enum.reduce_while(stats, {:ok, draft}, fn {stat, value}, {:ok, draft} ->
      case CharacterCreation.set_stat(draft, stat, value) do
        {:ok, draft} -> {:cont, {:ok, draft}}
        error -> {:halt, error}
      end
    end)
  end

  defp race_bonus(draft, nil), do: {:ok, draft}
  defp race_bonus(draft, picks), do: CharacterCreation.pick_race_bonus(draft, picks)
end
