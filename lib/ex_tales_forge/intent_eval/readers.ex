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

  require Logger

  alias TalesForge.Game.{Context, Intent, JevIntent, Prompts, Variant}
  alias TalesForge.Game.Schemas.{IntentExtraction, SingleAction}
  alias TalesForge.LLM

  @jev_model "jev-1.13.0"
  @default_timeout_ms 4_000

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
          optional(:raw_confidence) => float(),
          optional(:probabilities) => %{atom() => %{atom() => float()}}
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
        max_retries: Keyword.get(jev_opts, :max_retries, 0),
        receive_timeout: Keyword.get(jev_opts, :timeout_ms, @default_timeout_ms)
      ]
      |> maybe_key(Keyword.get(jev_opts, :api_key))

    case cached_post(state, questions, post_opts, Keyword.get(jev_opts, :cache_dir)) do
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

  # With a cache dir, a reply is stored under the SHA-256 of the exact request
  # (model, state, questions), so re-running with unchanged requests (e.g. while
  # tuning post-processing or the calibration map) costs nothing, and any change
  # to the request misses the cache and calls Jev again.
  defp cached_post(state, questions, post_opts, nil) do
    with {:ok, reply} <- Jev.HTTP.post(state, questions, post_opts), do: {:ok, reply, false}
  end

  defp cached_post(state, questions, post_opts, dir) do
    path = Path.join(dir, request_key(state, questions, post_opts[:model]) <> ".etf")

    case File.read(path) do
      {:ok, binary} ->
        {:ok, :erlang.binary_to_term(binary), true}

      {:error, _} ->
        with {:ok, reply} <- Jev.HTTP.post(state, questions, post_opts) do
          File.mkdir_p!(dir)
          File.write!(path, :erlang.term_to_binary(reply))
          {:ok, reply, false}
        end
    end
  end

  @doc """
  The cache key of a Jev request: the hex SHA-256 of its content (`model`,
  `state`, `questions`) in a canonical form, with every map's keys sorted.

  The JSON body itself is not stable across VMs: since OTP 26 small maps order
  atom keys by the atom table, not alphabetically, so label order in the body
  depends on which atoms a VM created first. The key does not.
  """
  @spec request_key(map(), keyword(), String.t() | nil) :: String.t()
  def request_key(state, questions, model) do
    %{model: model, state: state, questions: Jev.questions(questions)}
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(%_{} = struct), do: struct |> Map.from_struct() |> canonical()

  defp canonical(map) when is_map(map),
    do: map |> Enum.map(fn {k, v} -> {to_string(k), canonical(v)} end) |> Enum.sort()

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(atom) when is_atom(atom) and atom not in [nil, true, false], do: to_string(atom)
  defp canonical(other), do: other

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
      probabilities: reading.probabilities
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
      cost: cost,
      cached: false
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
      cost: 0.0,
      cached: false
    }
  end
end
