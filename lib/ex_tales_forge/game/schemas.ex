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
    @moduledoc """
    One action the player wants to take: its type, target and parameters (e.g. `"item_id"`).
    """
    @type t :: %__MODULE__{}

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
    @moduledoc """
    One option offered to the player when the intent step asks a clarifying question.
    """
    @type t :: %__MODULE__{}

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
    @moduledoc """
    The intent step's reading of the player's free text, before validation.
    """
    @type t :: %__MODULE__{}

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
    @moduledoc """
    The validated player action for a turn: overall intent, the primary `SingleAction`, confidence and any deferred actions.
    """
    @type t :: %__MODULE__{}

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
    @moduledoc """
    The server's resolution of an action (skill, roll, outcome, state changes) that bounds what the GM may narrate.
    """
    @type t :: %__MODULE__{}

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
    @moduledoc """
    A decoded GM reply: the narrative plus bookkeeping (NPC memory updates, context summary, GM notes), capped when parsed.
    """

    # Hard caps on the GM's bookkeeping, enforced here rather than with
    # maxLength / maxItems in the narration schema (those turn off xAI prompt
    # caching; see TalesForge.LLM.narration_schema/0). gm_system.txt asks for
    # less, so the caps only bite on a runaway reply.
    @gm_notes_max_chars 240
    @context_summary_max_chars 300
    @npc_memory_max_items 3
    @npc_memory_max_chars 160

    def caps,
      do: %{
        gm_notes: @gm_notes_max_chars,
        context_summary: @context_summary_max_chars,
        npc_memory_items: @npc_memory_max_items,
        npc_memory_summary: @npc_memory_max_chars
      }

    @type t :: %__MODULE__{}

    defstruct [
      :narrative,
      mechanical_resolution: %MechanicalResolution{},
      npc_memory_updates: [],
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
        npc_memory_updates: memories(Map.get(map, "npc_memory_updates")),
        context_summary: cap(Map.get(map, "context_summary"), @context_summary_max_chars),
        gm_notes: map |> Map.get("gm_notes") |> notes() |> cap(@gm_notes_max_chars),
        raw: map
      }
    end

    defp notes(notes) when is_binary(notes) and notes != "", do: notes
    defp notes(_notes), do: nil

    defp memories(list) when is_list(list) do
      list
      |> Enum.take(@npc_memory_max_items)
      |> Enum.map(fn
        %{"summary" => summary} = m -> %{m | "summary" => cap(summary, @npc_memory_max_chars)}
        other -> other
      end)
    end

    defp memories(_), do: []

    defp cap(text, max) when is_binary(text), do: String.slice(text, 0, max)
    defp cap(other, _max), do: other
  end

  defmodule HandlerResult do
    @moduledoc """
    Which action handler took the action, with its skill, target, notes and hints for the state update.
    """
    @type t :: %__MODULE__{}

    defstruct [:handler, :skill, :target, notes: "", state_hints: %{}]
  end
end
