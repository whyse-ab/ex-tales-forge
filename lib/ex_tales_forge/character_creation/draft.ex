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
  * `skill_buys` are the skill levels bought with skill points, on top of the
    free levels (class package, race bonus). Kept as levels above the free
    ones, so a new race or class keeps what the player bought.
  * `edited` holds the parts the player has set (`:stats`, `:race_picks`,
    `:skills`), so a new race or class re-suggests only what the player hasn't
    touched.
  """

  @enforce_keys [:adventure_id, :seed_key]
  defstruct adventure_id: nil,
            seed_key: nil,
            name: "",
            race: "human",
            class: "none",
            base_stats: %{},
            race_picks: [],
            skill_buys: %{},
            edited: MapSet.new()

  @type t :: %__MODULE__{
          adventure_id: String.t(),
          seed_key: String.t(),
          name: String.t(),
          race: String.t(),
          class: String.t(),
          base_stats: %{optional(String.t()) => integer()},
          race_picks: [String.t()],
          skill_buys: %{optional(String.t()) => pos_integer()},
          edited: MapSet.t(atom())
        }
end
