defmodule TalesForge.Social.Hearing do
  @moduledoc """
  Who hears what, computed in game code (`docs/design-social-layer.md` §2).
  Pure: no LLM, no Repo, not wired into the turn yet.

  The speaker's voice has a level at 1 m, which rises in noise (the Lombard
  effect) for talk and shout but not for a whisper. The level falls with
  distance by the inverse square law (−6 dB per doubling, distances under
  0.25 m count as 0.25 m). The listener's hearing modifier adds to the
  signal-to-noise ratio (SNR):

      snr_db = voice_db − 20·log10(max(distance_m, 0.25)) − ambient_db + hearing_db

  An SNR of −3 dB or more is clear, −12 up to −3 dB is partial (keep rises
  linearly from 0.3 to 0.9), below −12 dB is none. The dB values and
  thresholds are the decided values (Fredrik, 2026-10-19, #489), tuned in
  playtest.

  The fragment seed comes from (session, turn, listener_id) (`seed/3`), so
  replays are deterministic.
  """

  alias TalesForge.GameCharacter
  alias TalesForge.Social.{Clarity, Listener, Utterance}

  @whisper_db 40
  @talk_db 60
  @shout_db 85
  @min_distance_m 0.25
  @clear_db -3
  @none_db -12
  @keep_low 0.3
  @keep_high 0.9
  @race_db %{"elf" => 3, "half_elf" => 1}
  @perception_step 25
  @perception_max_db 4
  @gap "…"

  @doc """
  The clarity of `utterance` for `listener`.

      iex> alias TalesForge.Social.{Hearing, Listener, Utterance}
      iex> Hearing.clarity(%Utterance{speaker_id: "pc", voice: :talk}, %Listener{character_id: "innkeep", distance_m: 1.0})
      %TalesForge.Social.Clarity{level: :clear, snr_db: 10.0, keep: 1.0}
  """
  @spec clarity(Utterance.t(), Listener.t()) :: Clarity.t()
  def clarity(%Utterance{voice: :none}, %Listener{}), do: %Clarity{}

  def clarity(%Utterance{} = utterance, %Listener{} = listener) do
    snr = snr_db(utterance, listener)
    %Clarity{level: level(snr), snr_db: snr, keep: keep(snr)}
  end

  @doc """
  The voice level at 1 m in dB, with the Lombard rise in noise: talk
  `min(max(60, ambient + 8), 75)`, shout `min(max(85, ambient + 15), 90)`,
  a whisper stays at 40.

      iex> TalesForge.Social.Hearing.voice_db(:talk, 70)
      75
  """
  @spec voice_db(Utterance.voice(), number()) :: number()
  def voice_db(:whisper, _ambient_db), do: @whisper_db
  def voice_db(:talk, ambient_db), do: min(max(@talk_db, ambient_db + 8), 75)
  def voice_db(:shout, ambient_db), do: min(max(@shout_db, ambient_db + 15), 90)

  @doc "The SNR in dB at the listener's ear (see the module doc)."
  @spec snr_db(Utterance.t(), Listener.t()) :: float()
  def snr_db(%Utterance{voice: voice, ambient_db: ambient}, %Listener{} = listener) do
    loss = 20 * :math.log10(max(listener.distance_m, @min_distance_m))
    voice_db(voice, ambient) - loss - ambient + listener.hearing_db
  end

  defp level(snr) when snr >= @clear_db, do: :clear
  defp level(snr) when snr >= @none_db, do: :partial
  defp level(_snr), do: :none

  defp keep(snr) when snr >= @clear_db, do: 1.0
  defp keep(snr) when snr < @none_db, do: 0.0

  defp keep(snr),
    do: @keep_low + (snr - @none_db) / (@clear_db - @none_db) * (@keep_high - @keep_low)

  @doc """
  The hearing modifier of a character in dB: race (elf +3, half-elf +1) plus
  the `perception` skill level / 25 rounded down (0..+4). No branch on PC or
  NPC; without the `perception` skill (skill list v1) it adds 0.

      iex> TalesForge.Social.Hearing.modifier(%TalesForge.GameCharacter{race: "elf", skills: %{"perception" => 30}})
      4
  """
  @spec modifier(GameCharacter.t()) :: integer()
  def modifier(%GameCharacter{race: race, skills: skills}) do
    Map.get(@race_db, race, 0) + perception_db(Map.get(skills || %{}, "perception", 0))
  end

  defp perception_db(level) when is_integer(level) and level > 0,
    do: min(div(level, @perception_step), @perception_max_db)

  defp perception_db(_level), do: 0

  @doc """
  What a listener caught of `text`: each word (split on whitespace) is kept
  when a draw seeded by `seed` is below `keep`, and a run of dropped words
  becomes one "…". The same seed gives the same fragment.

      iex> alias TalesForge.Social.{Clarity, Hearing}
      iex> Hearing.fragment("I take the ale", %Clarity{level: :clear, keep: 1.0}, 7)
      "I take the ale"
  """
  @spec fragment(String.t(), Clarity.t(), integer()) :: String.t()
  def fragment(text, %Clarity{keep: keep}, seed) do
    {words, _state} =
      text
      |> String.split()
      |> Enum.map_reduce(:rand.seed_s(:exsss, seed), &draw(&1, &2, keep))

    words
    |> Enum.chunk_by(&is_nil/1)
    |> Enum.map_join(" ", fn [word | _] = run -> if word, do: Enum.join(run, " "), else: @gap end)
  end

  defp draw(word, state, keep) do
    {x, state} = :rand.uniform_s(state)
    {if(x < keep, do: word), state}
  end

  @doc """
  The fragment seed of a listener in a turn,
  `:erlang.phash2({session_id, turn_number, listener_id})`, so a replay and a
  test give the same fragment.
  """
  @spec seed(String.t(), non_neg_integer(), String.t()) :: non_neg_integer()
  def seed(session_id, turn_number, listener_id),
    do: :erlang.phash2({session_id, turn_number, listener_id})
end
