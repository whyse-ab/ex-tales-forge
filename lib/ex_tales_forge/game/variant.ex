defmodule TalesForge.Game.Variant do
  @moduledoc """
  A session's behaviour variant, fixed when the session is created and stored
  as `world_state["variant"]`.

  - `"default"`: the current game. Sessions without the key play this.
  - `"baseline"`: the game as it was before the 2026-10-07 rework (rolls on
    ordinary talk, the old Brenna and GM prompt rules). It is kept so a
    comparison can run both arms on the same deploy, interleaved, and tagged
    per run (`TalesForge.Playtest.RunMeta`). Delete it, with
    `priv/prompts/variants/baseline/` and the pack `variants/baseline/`
    folders, once the comparison is done.

  A variant swaps whole authored files: `priv/prompts/variants/<variant>/<file>`
  replaces `priv/prompts/<file>` when it exists. Code that behaves differently
  asks `baseline?/1`.

  New sessions get `GAME_VARIANT` (`TalesForge.Config.game_variant/0`, default
  `"default"`) unless the caller names one, e.g. the playtest runner's
  `variant:` option.
  """

  @variants ~w(default baseline)

  @typedoc "A known variant name."
  @type t :: String.t()

  @doc ~S"""
  The known variants.

      iex> TalesForge.Game.Variant.all()
      ["default", "baseline"]
  """
  @spec all() :: [t()]
  def all, do: @variants

  @doc ~S"""
  The variant of a session's world_state (or of an intent context map, which
  carries `"variant"` too). Missing or unknown means `"default"`.

      iex> TalesForge.Game.Variant.of(%{"variant" => "baseline"})
      "baseline"
      iex> TalesForge.Game.Variant.of(%{})
      "default"
      iex> TalesForge.Game.Variant.of(nil)
      "default"
  """
  @spec of(map() | nil) :: t()
  def of(%{"variant" => variant}) when variant in @variants, do: variant
  def of(_world_or_context), do: "default"

  @doc "True when the world_state or context plays the baseline variant."
  @spec baseline?(map() | nil) :: boolean()
  def baseline?(world_or_context), do: of(world_or_context) == "baseline"

  @doc ~S"""
  Validates a requested variant: `{:ok, variant}` for a known name or nil (the
  configured default), else `{:error, :unknown_variant}`.

      iex> TalesForge.Game.Variant.cast("baseline")
      {:ok, "baseline"}
      iex> TalesForge.Game.Variant.cast("nope")
      {:error, :unknown_variant}
  """
  @spec cast(String.t() | nil) :: {:ok, t()} | {:error, :unknown_variant}
  def cast(nil), do: {:ok, configured()}
  def cast(""), do: {:ok, configured()}
  def cast(variant) when variant in @variants, do: {:ok, variant}
  def cast(_variant), do: {:error, :unknown_variant}

  @doc """
  `world` with the variant stored. `"default"` is not stored, so a default
  session's world_state is unchanged.
  """
  @spec put(map(), t()) :: map()
  def put(world, "default") when is_map(world), do: Map.delete(world, "variant")

  def put(world, variant) when is_map(world) and variant in @variants,
    do: Map.put(world, "variant", variant)

  defp configured do
    variant = TalesForge.Config.game_variant()
    if variant in @variants, do: variant, else: "default"
  end
end
