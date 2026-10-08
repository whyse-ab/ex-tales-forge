defmodule TalesForge.Game.Features do
  @moduledoc """
  World features of a session, fixed when the session is created and stored
  as `world_state["features"]` (like `TalesForge.Game.Variant`). Turning a
  flag on or off changes new sessions only.

  - `"inn_world"` (`INN_WORLD=on`): the places and people around the Valley
    Inn, from the pack extension `extensions/inn_world/`.
  - `"antagonist"` (`WORLD_ANTAGONIST=on`, needs `inn_world`): the Tinjacks,
    from `extensions/antagonist/`.

  The baseline variant gets no features. Design: tales-forge-docs
  `docs/design-tin-valley-world.md`.
  """

  alias TalesForge.Config
  alias TalesForge.Game.Variant

  @known ~w(inn_world antagonist)
  @requires %{"antagonist" => "inn_world"}

  @typedoc "A known feature name."
  @type t :: String.t()

  @doc ~S"""
  The known features, in load order.

      iex> TalesForge.Game.Features.all()
      ["inn_world", "antagonist"]
  """
  @spec all() :: [t()]
  def all, do: @known

  @doc """
  The features a new session of `variant` gets from the env flags. None for
  the baseline variant; `antagonist` only together with `inn_world`.
  """
  @spec for_new_session(Variant.t()) :: [t()]
  def for_new_session(variant) do
    if variant == "baseline" do
      []
    else
      [{"inn_world", Config.inn_world?()}, {"antagonist", Config.world_antagonist?()}]
      |> Enum.filter(fn {_feature, on?} -> on? end)
      |> Enum.map(fn {feature, _on?} -> feature end)
      |> normalize()
    end
  end

  @doc ~S"""
  Known features in load order, without duplicates and without features whose
  requirement is missing.

      iex> TalesForge.Game.Features.normalize(["antagonist", "inn_world", "nope"])
      ["inn_world", "antagonist"]
      iex> TalesForge.Game.Features.normalize(["antagonist"])
      []
  """
  @spec normalize([String.t()] | nil) :: [t()]
  def normalize(features) do
    wanted = MapSet.new(List.wrap(features))

    Enum.filter(@known, fn feature ->
      MapSet.member?(wanted, feature) and
        (is_nil(@requires[feature]) or MapSet.member?(wanted, @requires[feature]))
    end)
  end

  @doc ~S"""
  The features of a world_state (or intent context).

      iex> TalesForge.Game.Features.of(%{"features" => ["inn_world"]})
      ["inn_world"]
      iex> TalesForge.Game.Features.of(%{})
      []
  """
  @spec of(map() | nil) :: [t()]
  def of(%{"features" => features}) when is_list(features), do: normalize(features)
  def of(_world), do: []

  @doc "True when the world_state has `feature`."
  @spec on?(map() | nil, t()) :: boolean()
  def on?(world, feature), do: feature in of(world)
end
