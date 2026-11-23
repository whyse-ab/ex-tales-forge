defmodule TalesForge.IntentEval.Readers do
  @moduledoc """
  The intent readers the evaluation compares, each normalised to one shape so
  `TalesForge.IntentEval.Metrics` can score them side by side:

    * `:jev` — the proposed one-call TypeSafe read (`TalesForge.Game.JevIntent`);
    * `:heuristic` — the rule-based fallback (`TalesForge.Game.Intent.heuristic_intent/2`).

  The `:jev` reader is the only one that calls the network, through
  `Jev.HTTP.post/3`; in tests `Req.Test` stubs it. The `:heuristic` reader is
  pure.
  """

  require Logger

  alias TalesForge.Game.{Intent, JevIntent, SelfCheck}
  alias TalesForge.Game.Schemas.{IntentExtraction, SingleAction}
  alias TalesForge.IntentEval.JevRequest

  @jev_model "jev-1.13.0"
  @default_timeout_ms 4_000

  defmodule Input do
    @moduledoc """
    One eval item and its live context, as `TalesForge.IntentEval.Readers.read/3`
    takes them.
    """
    defstruct [:item, context: %{}]

    @typedoc "One eval item and its live context."
    @type t :: %__MODULE__{item: map(), context: map()}
  end

  @typedoc "A reader's normalised reading of one item."
  @type reading :: %{
          required(:reader) => atom(),
          required(:status) => :ok | :error | :unavailable,
          required(:action) => atom() | nil,
          required(:target) => String.t() | nil,
          required(:skill) => String.t() | nil,
          required(:later) => atom() | nil,
          required(:later_target) => String.t() | nil,
          required(:safety) => atom(),
          required(:confidence) => float() | nil,
          required(:benign_probability) => float() | nil,
          required(:action_probabilities) => %{atom() => float()},
          required(:top2) => [atom()],
          required(:cost) => float(),
          required(:cached) => boolean(),
          optional(:self_check) => [SelfCheck.ask()] | nil,
          optional(:raw_confidence) => float(),
          optional(:probabilities) => %{atom() => %{atom() => float()}}
        }

  @doc "Reads the input's item with `reader` over its live context."
  @spec read(atom(), Input.t(), keyword()) :: reading()
  def read(:heuristic, %Input{item: item, context: context}, _opts), do: heuristic(item, context)

  def read(:jev, %Input{item: item, context: context}, opts),
    do: jev(item, context, Keyword.get(opts, :jev, []))

  # --- heuristic ---------------------------------------------------------------

  # The heuristic also reads self-checks with the narrow text fallback.
  defp heuristic(item, context) do
    item["text"]
    |> Intent.heuristic_intent(context)
    |> from_extraction()
    |> Map.put(:self_check, SelfCheck.asks(item["text"]))
  end

  # --- jev ---------------------------------------------------------------------

  defp jev(item, context, jev_opts) do
    %{candidates: candidates, state: state, questions: questions} =
      JevRequest.request(context, item["text"], jev_opts)

    post_opts =
      [
        model: Keyword.get(jev_opts, :model, @jev_model),
        max_retries: Keyword.get(jev_opts, :max_retries, 0),
        receive_timeout: Keyword.get(jev_opts, :timeout_ms, @default_timeout_ms)
      ]
      |> maybe_key(Keyword.get(jev_opts, :api_key))

    request = %{state: state, questions: questions}

    case JevRequest.cached_post(request, post_opts, Keyword.get(jev_opts, :cache_dir)) do
      {:ok, reply, cached?} ->
        reading = JevIntent.decode(reply, candidates, text: item["text"], context: context)
        reading |> from_jev() |> Map.put(:cached, cached?)

      {:error, reason} ->
        Logger.warning("intent eval: jev error item=#{item["id"]} reason=#{error_reason(reason)}")
        %{blank(:jev) | status: :error}
    end
  rescue
    e ->
      Logger.warning("intent eval: jev crashed item=#{item["id"]} error=#{Exception.message(e)}")
      %{blank(:jev) | status: :error}
  end

  defp error_reason(%{status: status}) when is_integer(status), do: "http_#{status}"
  defp error_reason(%{reason: reason}), do: inspect(reason)
  defp error_reason(other), do: inspect(other.__struct__)

  defdelegate request(context, text), to: JevRequest
  defdelegate request(context, text, switches), to: JevRequest
  defdelegate request_key(state, questions, model), to: JevRequest

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
      cost: reading.cost,
      cached: false,
      raw_confidence: reading.raw_confidence,
      probabilities: reading.probabilities,
      self_check: reading.self_check
    }
  end

  # --- shared ------------------------------------------------------------------

  # The heuristic's reading: free, and always read.
  defp from_extraction(%IntentExtraction{} = extraction) do
    primary =
      Enum.at(extraction.actions, extraction.primary_index) || List.first(extraction.actions)

    deferred = deferred_action(extraction)

    %{
      reader: :heuristic,
      status: :ok,
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
      cost: 0.0,
      cached: false
    }
  end

  defp deferred_action(%IntentExtraction{actions: actions, primary_index: index}),
    do: actions |> List.delete_at(index) |> List.first()

  defp action_type(%SingleAction{action_type: type}), do: type
  defp action_type(_), do: nil

  defp target(%SingleAction{target: target}), do: target
  defp target(_), do: nil

  defp skill(%SingleAction{parameters: params}) when is_map(params), do: Map.get(params, "skill")
  defp skill(_), do: nil

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
      cost: 0.0,
      cached: false
    }
  end
end
