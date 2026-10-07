defmodule TalesForge.CharacterCreation.Draft do
  @moduledoc """
  A player character being created. Pure data, kept by whoever drives creation
  (the creation screen or the persona runner) and changed only through
  `TalesForge.CharacterCreation`.

  * `seed_key` seeds the small per-character variation in the derived OCEAN, so
    a draft gives the same character every time it is finalised.
  * `base_stats` are the point-buy stats before the race modifier.
  * `race_picks` are the stats chosen for a race bonus with a choice (Human: any
    two; Elf: INT or WIS).
  * `edited` holds the parts the player has set (`:stats`, `:race_picks`), so a
    new race or class re-suggests only what the player hasn't touched.
  """

  @enforce_keys [:adventure_id, :seed_key]
  defstruct adventure_id: nil,
            seed_key: nil,
            name: "",
            race: "human",
            class: "none",
            base_stats: %{},
            race_picks: [],
            edited: MapSet.new()

  @type t :: %__MODULE__{
          adventure_id: String.t(),
          seed_key: String.t(),
          name: String.t(),
          race: String.t(),
          class: String.t(),
          base_stats: %{optional(String.t()) => integer()},
          race_picks: [String.t()],
          edited: MapSet.t(atom())
        }
end
