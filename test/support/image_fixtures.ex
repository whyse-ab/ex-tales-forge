defmodule TalesForge.ImageFixtures do
  @moduledoc "Small image bytes for the image store tests (`TalesForge.Images`)."

  @doc "A 1×1 PNG."
  @spec png() :: binary()
  def png,
    do:
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
      )

  @doc "GIF bytes (not a type the store keeps)."
  @spec gif() :: binary()
  def gif, do: "GIF89a" <> :binary.copy(<<0>>, 20)
end
