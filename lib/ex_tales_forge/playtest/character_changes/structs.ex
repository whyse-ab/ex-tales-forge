defmodule TalesForge.Playtest.CharacterChanges.Field do
  @moduledoc """
  One row of a character's start-versus-end view in
  `TalesForge.Playtest.CharacterChanges`: a label, the value at the start of the
  run and at its end (both already formatted for display), whether it changed,
  and where the values were read from.

  `status` is `:changed`, `:unchanged`, or `:not_tracked` when today's stored
  state cannot say (then `end_value` is nil and `note` says why).
  """

  @typedoc "Whether the field changed over the run, or cannot be told."
  @type status :: :changed | :unchanged | :not_tracked

  @typedoc "A start-versus-end row."
  @type t :: %__MODULE__{
          key: atom(),
          label: String.t(),
          start_value: String.t() | nil,
          end_value: String.t() | nil,
          status: status(),
          source: String.t(),
          note: String.t() | nil
        }

  @enforce_keys [:key, :label, :status, :source]
  defstruct [:key, :label, :start_value, :end_value, :status, :source, :note]
end

defmodule TalesForge.Playtest.CharacterChanges.Memory do
  @moduledoc """
  One memory a character gained during a run, with the turn it was written in
  (nil when the turn cannot be told) and who wrote it:

    * `:gm`: the GM's `npc_memory_updates`;
    * `:heard`: the NPC agent heard the player speak to it;
    * `:overheard`: the NPC agent overheard someone;
    * `:world`: a world move (front or `WorldSim`), with a `felt` label;
    * `:unknown`: none of the above could be matched.
  """

  @typedoc "Who wrote the memory."
  @type source :: :gm | :heard | :overheard | :world | :unknown

  @typedoc "A memory added during the run."
  @type t :: %__MODULE__{
          turn_number: pos_integer() | nil,
          tick: integer() | nil,
          text: String.t(),
          felt: String.t() | nil,
          source: source()
        }

  @enforce_keys [:text, :source]
  defstruct [:turn_number, :tick, :text, :felt, :source]
end

defmodule TalesForge.Playtest.CharacterChanges.Character do
  @moduledoc """
  One character's changes over a run: the player character (`kind: :pc`) or an
  NPC (`kind: :npc`). `fields` are the start-versus-end rows that can be read
  from the stored state, `not_tracked` the rows it cannot answer yet, and
  `memories_added` the memories gained during the run, oldest first.
  `changed?` is true when any field changed or a memory was added.
  """

  alias TalesForge.Playtest.CharacterChanges.{Field, Memory}

  @typedoc "Player character or NPC."
  @type kind :: :pc | :npc

  @typedoc "A character's changes."
  @type t :: %__MODULE__{
          slug: String.t(),
          name: String.t(),
          kind: kind(),
          controller: String.t() | nil,
          fields: [Field.t()],
          not_tracked: [Field.t()],
          memories_added: [Memory.t()],
          changed?: boolean()
        }

  @enforce_keys [:slug, :name, :kind]
  defstruct [
    :slug,
    :name,
    :kind,
    :controller,
    fields: [],
    not_tracked: [],
    memories_added: [],
    changed?: false
  ]
end

defmodule TalesForge.Playtest.CharacterChanges.Change do
  @moduledoc """
  One entry in a turn of the per-turn timeline: which character changed, what
  kind of change (`:memory`, `:travel`, `:learning`, `:reaction`) and a short
  text for the admin page.
  """

  @typedoc "The kind of change."
  @type kind :: :memory | :travel | :learning | :reaction

  @typedoc "One change in a turn."
  @type t :: %__MODULE__{slug: String.t(), name: String.t(), kind: kind(), text: String.t()}

  @enforce_keys [:slug, :name, :kind, :text]
  defstruct [:slug, :name, :kind, :text]
end

defmodule TalesForge.Playtest.CharacterChanges.TurnEntry do
  @moduledoc """
  One turn of the per-turn timeline: the turn number and id (for links) and
  the changes recorded for it. Turns without changes are left out.
  """

  alias TalesForge.Playtest.CharacterChanges.Change

  @typedoc "A turn's changes."
  @type t :: %__MODULE__{
          turn_number: pos_integer() | nil,
          turn_id: String.t() | nil,
          changes: [Change.t()]
        }

  @enforce_keys [:turn_number]
  defstruct [:turn_number, :turn_id, changes: []]
end

defmodule TalesForge.Playtest.CharacterChanges.RunMetrics do
  @moduledoc """
  The per-run numbers behind the batch summary
  (`TalesForge.Playtest.CharacterChanges.run_metrics/1`):

    * `memories_added`: memories gained by any character during the run;
    * `npcs_changed`: NPCs with at least one change (field or memory);
    * `npcs_attitude_changed`: NPCs whose Jev stance or relationship score
      toward the player character changed;
    * `stance_changed?`: some NPC's latest kept Jev stance toward the player
      character is not the neutral it starts from;
    * `relationship_changed?`: some NPC's `relationship_score` moved off 0.0;
    * `attitude_changed?`: either of the two;
    * `reactions_tracked?`: the run has Jev NPC reactions at all
      (`NPC_REACTIONS` on), so a false `stance_changed?` means something.
  """

  @typedoc "Per-run character-change numbers."
  @type t :: %__MODULE__{
          memories_added: non_neg_integer(),
          npcs_changed: non_neg_integer(),
          npcs_attitude_changed: non_neg_integer(),
          stance_changed?: boolean(),
          relationship_changed?: boolean(),
          attitude_changed?: boolean(),
          reactions_tracked?: boolean()
        }

  defstruct memories_added: 0,
            npcs_changed: 0,
            npcs_attitude_changed: 0,
            stance_changed?: false,
            relationship_changed?: false,
            attitude_changed?: false,
            reactions_tracked?: false
end

defmodule TalesForge.Playtest.CharacterChanges.Summary do
  @moduledoc """
  Character changes over a batch of runs
  (`TalesForge.Playtest.CharacterChanges.summarize/1`):

    * `runs`: runs summarised;
    * `attitude_changed`, `attitude_changed_share`: runs (and their share)
      where an NPC's attitude toward the player character changed, by Jev
      stance or relationship score; `stance_changed` and
      `relationship_changed` count the two signals apart;
    * `reaction_runs`: runs that had Jev NPC reactions at all;
    * `memories_median`, `memories_mean`: memories added per run;
    * `npcs_changed_median`, `npcs_changed_mean`: NPCs with any change per run;
    * `attitude_npcs_median`, `attitude_npcs_mean`: NPCs per run whose attitude
      toward the player character changed (the share above is near 100% once
      NPC reactions are on; this tells runs apart).

  Shares, medians and means are nil for an empty batch.
  """

  @typedoc "Batch summary."
  @type t :: %__MODULE__{
          runs: non_neg_integer(),
          attitude_changed: non_neg_integer(),
          attitude_changed_share: float() | nil,
          stance_changed: non_neg_integer(),
          relationship_changed: non_neg_integer(),
          reaction_runs: non_neg_integer(),
          memories_median: float() | nil,
          memories_mean: float() | nil,
          npcs_changed_median: float() | nil,
          npcs_changed_mean: float() | nil,
          attitude_npcs_median: float() | nil,
          attitude_npcs_mean: float() | nil
        }

  defstruct runs: 0,
            attitude_changed: 0,
            attitude_changed_share: nil,
            stance_changed: 0,
            relationship_changed: 0,
            reaction_runs: 0,
            memories_median: nil,
            memories_mean: nil,
            npcs_changed_median: nil,
            npcs_changed_mean: nil,
            attitude_npcs_median: nil,
            attitude_npcs_mean: nil
end
