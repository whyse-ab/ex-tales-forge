defmodule TalesForge.Game.Gestures.Forms do
  @moduledoc """
  English verb forms for the gesture patterns of `TalesForge.Game.Gestures`
  (compile-time helper; regular verbs only).
  """

  @doc """
  The base form, the third person, the -ing form and the past of a regular verb.

      iex> TalesForge.Game.Gestures.Forms.verb("wipe")
      ["wipe", "wipes", "wiping", "wiped"]

      iex> TalesForge.Game.Gestures.Forms.verb("tap")
      ["tap", "taps", "tapping", "tapped"]

      iex> TalesForge.Game.Gestures.Forms.verb("scratch")
      ["scratch", "scratches", "scratching", "scratched"]
  """
  @spec verb(String.t()) :: [String.t()]
  def verb(base) when is_binary(base) do
    cond do
      String.ends_with?(base, "e") ->
        stem = String.slice(base, 0..-2//1)
        [base, base <> "s", stem <> "ing", base <> "d"]

      String.ends_with?(base, ~w(sh ch ss x)) ->
        [base, base <> "es", base <> "ing", base <> "ed"]

      Regex.match?(~r/^[^aeiou]*[aeiou][bdgmnpt]$/, base) ->
        last = String.last(base)
        [base, base <> "s", base <> last <> "ing", base <> last <> "ed"]

      true ->
        [base, base <> "s", base <> "ing", base <> "ed"]
    end
  end
end
