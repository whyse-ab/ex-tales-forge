defmodule TalesForge.Game.Schemas do
  @moduledoc """
  Game data structures for intent extraction and GM responses.
  """

  @type action_type ::
          :observe
          | :interact
          | :speak
          | :move
          | :combat
          | :use_item
          | :pickup
          | :drop
          | :buy
          | :sell
          | :trade
          | :spend
          | :wait
          | :train
          | :freeform
          | :other

  defmodule SingleAction do
    @moduledoc false
    defstruct [:action_type, :target, parameters: %{}]

    def decode(map) when is_map(map) do
      type =
        map
        |> Map.get("action_type", "other")
        |> to_string()
        |> String.downcase()
        |> action_type_atom()

      %__MODULE__{
        action_type: type,
        target: Map.get(map, "target"),
        parameters: Map.get(map, "parameters", %{})
      }
    end

    defp action_type_atom(type) do
      case type do
        "observe" -> :observe
        "interact" -> :interact
        "speak" -> :speak
        "move" -> :move
        "combat" -> :combat
        "use_item" -> :use_item
        "pickup" -> :pickup
        "drop" -> :drop
        "buy" -> :buy
        "sell" -> :sell
        "trade" -> :trade
        "spend" -> :spend
        "wait" -> :wait
        "train" -> :train
        "freeform" -> :freeform
        _ -> :other
      end
    end

    def encode(%__MODULE__{} = action) do
      %{
        "action_type" => Atom.to_string(action.action_type),
        "target" => action.target,
        "parameters" => action.parameters
      }
    end
  end

  defmodule ClarificationOption do
    @moduledoc false
    defstruct [:id, :label, :description, action_index: 0]

    def decode(map) do
      %__MODULE__{
        id: Map.get(map, "id"),
        label: Map.get(map, "label"),
        description: Map.get(map, "description"),
        action_index: Map.get(map, "action_index", 0)
      }
    end
  end

  defmodule IntentExtraction do
    @moduledoc false
    defstruct [
      :overall_intent,
      actions: [],
      primary_index: 0,
      confidence: 1.0,
      needs_clarification: false,
      clarification_question: nil,
      clarification_options: []
    ]

    def decode(map) when is_map(map) do
      %__MODULE__{
        overall_intent: Map.get(map, "overall_intent", ""),
        actions: map |> Map.get("actions", []) |> Enum.map(&SingleAction.decode/1),
        primary_index: Map.get(map, "primary_index", 0),
        confidence: Map.get(map, "confidence", 1.0),
        needs_clarification: Map.get(map, "needs_clarification", false),
        clarification_question: Map.get(map, "clarification_question"),
        clarification_options:
          map |> Map.get("clarification_options", []) |> Enum.map(&ClarificationOption.decode/1)
      }
    end

    def encode(%__MODULE__{} = extraction) do
      %{
        "overall_intent" => extraction.overall_intent,
        "actions" => Enum.map(extraction.actions, &SingleAction.encode/1),
        "primary_index" => extraction.primary_index,
        "confidence" => extraction.confidence,
        "needs_clarification" => extraction.needs_clarification,
        "clarification_question" => extraction.clarification_question,
        "clarification_options" =>
          Enum.map(extraction.clarification_options, fn opt ->
            %{
              "id" => opt.id,
              "label" => opt.label,
              "description" => opt.description,
              "action_index" => opt.action_index
            }
          end)
      }
    end
  end

  defmodule PlayerAction do
    @moduledoc false
    defstruct [:overall_intent, :action, confidence: 1.0, deferred_actions: []]

    def decode(map) when is_map(map) do
      %__MODULE__{
        overall_intent: Map.get(map, "overall_intent", ""),
        action: map |> Map.get("action", %{}) |> SingleAction.decode(),
        confidence: Map.get(map, "confidence", 1.0),
        deferred_actions:
          map |> Map.get("deferred_actions", []) |> Enum.map(&SingleAction.decode/1)
      }
    end

    def encode(%__MODULE__{} = player_action) do
      %{
        "overall_intent" => player_action.overall_intent,
        "action" => SingleAction.encode(player_action.action),
        "confidence" => player_action.confidence,
        "deferred_actions" => Enum.map(player_action.deferred_actions, &SingleAction.encode/1)
      }
    end
  end

  defmodule MechanicalResolution do
    @moduledoc false
    defstruct skill: nil,
              outcome: "none",
              roll: nil,
              effective_skill: nil,
              lp_awarded: nil,
              notes: nil,
              improvements: [],
              training: nil

    def decode(map) when is_map(map) do
      %__MODULE__{
        skill: Map.get(map, "skill"),
        outcome: Map.get(map, "outcome", "none"),
        roll: Map.get(map, "roll"),
        effective_skill: Map.get(map, "effective_skill"),
        lp_awarded: Map.get(map, "lp_awarded"),
        notes: Map.get(map, "notes"),
        improvements: Map.get(map, "improvements") || [],
        training: Map.get(map, "training")
      }
    end

    def encode(%__MODULE__{} = res) do
      %{
        "skill" => res.skill,
        "outcome" => res.outcome,
        "roll" => res.roll,
        "effective_skill" => res.effective_skill,
        "lp_awarded" => res.lp_awarded,
        "notes" => res.notes,
        "improvements" => res.improvements || [],
        "training" => res.training
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
    end
  end

  defmodule GMStructuredResponse do
    @moduledoc false
    defstruct [
      :narrative,
      mechanical_resolution: %MechanicalResolution{},
      state_updates: [],
      npc_memory_updates: [],
      overlay_deltas: %{},
      context_summary: nil,
      gm_notes: nil,
      raw: %{}
    ]

    def decode(map) when is_map(map) do
      %__MODULE__{
        narrative: Map.get(map, "narrative", ""),
        mechanical_resolution:
          map
          |> Map.get("mechanical_resolution", %{})
          |> MechanicalResolution.decode(),
        state_updates: Map.get(map, "state_updates", []),
        npc_memory_updates: Map.get(map, "npc_memory_updates", []),
        overlay_deltas: Map.get(map, "overlay_deltas", %{}),
        context_summary: Map.get(map, "context_summary"),
        gm_notes: notes(Map.get(map, "gm_notes")),
        raw: map
      }
    end

    defp notes(notes) when is_binary(notes) and notes != "", do: notes
    defp notes(_notes), do: nil
  end

  defmodule HandlerResult do
    @moduledoc false
    defstruct [:handler, :skill, :target, notes: "", state_hints: %{}]
  end
end
