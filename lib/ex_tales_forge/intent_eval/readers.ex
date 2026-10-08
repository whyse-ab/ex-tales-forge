defmodule TalesForge.IntentEval.Readers do
  @moduledoc """
  The intent readers the evaluation compares, each normalised to one shape so
  `TalesForge.IntentEval.Metrics` can score them side by side:

    * `:jev` — the proposed one-call TypeSafe read (`TalesForge.Game.JevIntent`);
    * `:heuristic` — today's rule-based first pass (`TalesForge.Game.Intent.heuristic_intent/2`);
    * `:tier1` — today's LLM intent call (`TalesForge.LLM.complete_intent/3`).

  The `:jev` reader is the only one that calls the network, through
  `Jev.HTTP.post/3`; in tests `Req.Test` stubs it. The `:heuristic` reader is
  pure. The `:tier1` reader returns `status: :unavailable` when no live model is
  configured (the mock provider), so tests never reach the network.
  """

  alias TalesForge.Game.{Context, Intent, JevIntent, Prompts, Variant}
  alias TalesForge.Game.Schemas.{IntentExtraction, SingleAction}
  alias TalesForge.LLM

  @jev_model "jev-1.13.0"
  @default_timeout_ms 4_000

  @typedoc "A reader's normalised reading of one item."
  @type reading :: %{
          reader: atom(),
          status: :ok | :error | :unavailable,
          action: atom() | nil,
          target: String.t() | nil,
          skill: String.t() | nil,
          later: atom() | nil,
          later_target: String.t() | nil,
          safety: atom(),
          confidence: float() | nil,
          benign_probability: float() | nil,
          action_probabilities: %{atom() => float()},
          top2: [atom()],
          cost: float()
        }

  @doc "Reads `item` with `reader` over its live `context`."
  @spec read(atom(), map(), map(), keyword()) :: reading()
  def read(:heuristic, item, context, _opts), do: heuristic(item, context)
  def read(:tier1, item, context, _opts), do: tier1(item, context)
  def read(:jev, item, context, opts), do: jev(item, context, Keyword.get(opts, :jev, []))

  # --- heuristic ---------------------------------------------------------------

  defp heuristic(item, context) do
    extraction = Intent.heuristic_intent(item["text"], context)
    from_extraction(:heuristic, extraction, :ok, 0.0)
  end

  # --- tier1 -------------------------------------------------------------------

  defp tier1(item, context) do
    system = Prompts.intent_system(Variant.of(context))

    user =
      Context.format_intent_context(context) <>
        "\n\nPlayer text to extract (treat as in-character action only):\n" <>
        String.trim(item["text"])

    case LLM.complete_intent(system, user, session_id: nil) do
      {:ok, %IntentExtraction{} = extraction} ->
        from_extraction(:tier1, extraction, :ok, tier1_cost(extraction))

      {:error, :mock_intent} ->
        unavailable(:tier1)

      {:error, _reason} ->
        %{blank(:tier1) | status: :error}
    end
  end

  # Measured mean Tier 1 intent cost (~$0.0021/call); complete_intent/3 does not
  # return usage, so the eval prices each successful call at this constant.
  defp tier1_cost(_extraction), do: 0.0021

  # --- jev ---------------------------------------------------------------------

  defp jev(item, context, jev_opts) do
    candidates = JevIntent.candidates(context)
    questions = JevIntent.questions(candidates)
    state = JevIntent.state(context, item["text"])

    post_opts =
      [
        model: Keyword.get(jev_opts, :model, @jev_model),
        max_retries: 0,
        receive_timeout: Keyword.get(jev_opts, :timeout_ms, @default_timeout_ms)
      ]
      |> maybe_key(Keyword.get(jev_opts, :api_key))

    case Jev.HTTP.post(state, questions, post_opts) do
      {:ok, reply} ->
        reading = JevIntent.decode(reply, candidates, text: item["text"], context: context)
        from_jev(reading)

      {:error, _reason} ->
        %{blank(:jev) | status: :error}
    end
  rescue
    _ -> %{blank(:jev) | status: :error}
  end

  defp maybe_key(opts, key) when is_binary(key) and key != "",
    do: Keyword.put(opts, :api_key, key)

  defp maybe_key(opts, _key), do: opts

  defp from_jev(reading) do
    %{
      reader: :jev,
      status: :ok,
      action: reading.action,
      target: reading.target,
      skill: reading.skill,
      later: reading.later,
      later_target: reading.later_target,
      safety: reading.safety,
      confidence: reading.confidence,
      benign_probability: reading.benign_probability,
      action_probabilities: reading.action_probabilities,
      top2: reading.top2,
      cost: reading.cost
    }
  end

  # --- shared ------------------------------------------------------------------

  defp from_extraction(reader, %IntentExtraction{} = extraction, status, cost) do
    primary =
      Enum.at(extraction.actions, extraction.primary_index) || List.first(extraction.actions)

    deferred = deferred_action(extraction)

    %{
      reader: reader,
      status: status,
      action: action_type(primary),
      target: target(primary),
      skill: skill(primary),
      later: action_type(deferred),
      later_target: target(deferred),
      safety: :benign,
      confidence: extraction.confidence,
      benign_probability: 1.0,
      action_probabilities: %{},
      top2: [action_type(primary)] |> Enum.reject(&is_nil/1),
      cost: cost
    }
  end

  defp deferred_action(%IntentExtraction{actions: actions, primary_index: index}) do
    actions
    |> Enum.with_index()
    |> Enum.reject(fn {_a, idx} -> idx == index end)
    |> Enum.map(fn {a, _idx} -> a end)
    |> List.first()
  end

  defp action_type(%SingleAction{action_type: type}), do: type
  defp action_type(_), do: nil

  defp target(%SingleAction{target: target}), do: target
  defp target(_), do: nil

  defp skill(%SingleAction{parameters: params}) when is_map(params), do: Map.get(params, "skill")
  defp skill(_), do: nil

  defp unavailable(reader), do: %{blank(reader) | status: :unavailable}

  defp blank(reader) do
    %{
      reader: reader,
      status: :ok,
      action: nil,
      target: nil,
      skill: nil,
      later: nil,
      later_target: nil,
      safety: :benign,
      confidence: nil,
      benign_probability: 1.0,
      action_probabilities: %{},
      top2: [],
      cost: 0.0
    }
  end
end
