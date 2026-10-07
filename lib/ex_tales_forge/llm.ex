defmodule TalesForge.LLM do
  @moduledoc """
  Two-tier LLM client with mock fallback and JSON validation retry.
  """

  require Logger

  alias TalesForge.AICalls
  alias TalesForge.Config

  alias TalesForge.Game.Schemas.{
    GMStructuredResponse,
    HandlerResult,
    IntentExtraction,
    PlayerAction
  }

  @intent_schema %{
    "type" => "object",
    "required" => ["overall_intent", "actions"],
    "properties" => %{
      "overall_intent" => %{"type" => "string"},
      "actions" => %{"type" => "array", "minItems" => 1},
      "primary_index" => %{"type" => "integer"},
      "confidence" => %{"type" => "number"},
      "needs_clarification" => %{"type" => "boolean"},
      "clarification_question" => %{"type" => ["string", "null"]},
      "clarification_options" => %{"type" => "array"}
    }
  }

  @persona_schema %{
    "type" => "object",
    "required" => ["action"],
    "properties" => %{
      "action" => %{"type" => "string"},
      "option_id" => %{"type" => ["string", "null"]}
    }
  }

  @persona_max_tokens 200

  @scorer_schema %{
    "type" => "object",
    "required" => ["scores", "rationale"],
    "properties" => %{
      "scores" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "required" => ["criterion", "score", "evidence"],
          "properties" => %{
            "criterion" => %{"type" => "integer"},
            "score" => %{"type" => ["integer", "null"], "minimum" => 1, "maximum" => 5},
            "evidence" => %{"type" => "string"}
          }
        }
      },
      "rationale" => %{"type" => "string"}
    }
  }

  # Calls that share the session's x-grok-conv-id (see conv_id/1).
  @narration_purposes ~w(scene gm)

  @scorer_max_tokens 800
  @scorer_temperature 0.2

  # Output budget for gm_notes on top of the narration's TIER2_MAX_TOKENS.
  @gm_notes_max_tokens 100

  # No maxLength / maxItems in the schema: with them xAI does not reuse the
  # prompt cache for the request at all (every GM call came back with
  # cached_tokens 128, measured 2026-10-07; the same request without them hit
  # ~9.3k cached tokens). gm_system.txt asks for short bookkeeping and
  # GMStructuredResponse.decode/1 enforces the hard caps in code.

  # Appended (never prepended) on a retry, so the retry re-sends the original
  # messages byte for byte and still hits the prompt cache.
  @retry_correction "Your previous reply was not valid JSON for the required schema. " <>
                      "Reply to the same request again with ONLY the JSON object."

  @doc """
  Strict structured-output schema shared by the scene call and the GM turn
  (xAI `json_schema`, `strict: true`, name `narration`).

  `narrative` is the first property: strict decoding emits keys in schema order,
  so the player-facing text comes first. `Jason.OrderedObject` keeps that order
  on the wire (plain Elixir maps encode keys sorted).

  One schema for both calls on purpose: xAI places `response_format` ahead of
  the messages in its prompt cache, so a different schema on the scene call
  would stop it from warming the cache for GM turn 1. The scene fills
  `narrative` + `location_name`; the GM leaves `location_name` out.
  """
  @spec narration_schema() :: map()
  def narration_schema do
    %{
      "type" => "object",
      "required" => ["narrative"],
      "properties" => Jason.OrderedObject.new(narration_properties())
    }
  end

  defp narration_properties do
    [
      {"narrative", %{"type" => "string"}},
      {"location_name", %{"type" => ["string", "null"]}},
      {"npc_memory_updates",
       %{
         "type" => "array",
         "items" => %{
           "type" => "object",
           "required" => ["npc_id", "summary"],
           "properties" => %{
             "npc_id" => %{"type" => "string"},
             "summary" => %{"type" => "string"}
           }
         }
       }},
      {"context_summary", %{"type" => ["string", "null"]}},
      {"gm_notes", %{"type" => ["string", "null"]}}
    ]
  end

  @typedoc "Options for the `complete_*` calls: `:session_id` (conv id and cost rows), `:turn_number`."
  @type call_opts :: [session_id: String.t() | nil, turn_number: integer() | nil]

  @typedoc "A decoded JSON reply, or why there is none."
  @type result(reply) :: {:ok, reply} | {:error, term()}

  @doc ~s[The configured LLM provider (`LLM_PROVIDER`), e.g. `"xai"` or `"mock"`.]
  @spec provider() :: String.t()
  def provider, do: Config.llm_provider()

  @doc ~s(How a reply was produced, for the stored rows: `"mock"` for the mock model, else `"api"`.)
  @spec llm_source(String.t()) :: String.t()
  def llm_source("mock"), do: "mock"
  def llm_source(_), do: "api"

  @doc """
  Player intent extraction (tier 1): the player's free text as an
  `IntentExtraction`. Returns `{:error, :mock_intent}` with the mock model, so
  callers fall back to the heuristic.
  """
  @spec complete_intent(String.t(), String.t(), call_opts()) :: result(IntentExtraction.t())
  def complete_intent(system, user, opts \\ []) do
    model = tier1_model()

    if mock?(model) do
      {:error, :mock_intent}
    else
      complete_json(
        model,
        simple_messages(system, user),
        @intent_schema,
        Config.tier1_temperature(),
        tier: :tier1,
        max_tokens: Config.tier1_max_tokens(),
        session_id: opts[:session_id]
      )
      |> case do
        {:ok, map} -> {:ok, IntentExtraction.decode(map)}
        error -> error
      end
    end
  end

  @doc "Opening/arrival scene. `messages` come from `Prompts.scene_messages/1`."
  @spec complete_scene([map()], map(), call_opts()) ::
          result(%{location_name: String.t(), narrative: String.t()})
  def complete_scene(messages, intent_context, opts \\ [])
      when is_list(messages) and is_map(intent_context) do
    model = tier2_model()

    if mock?(model) do
      {:ok, mock_scene_response(intent_context)}
    else
      complete_json(model, messages, narration_schema(), Config.tier2_temperature(),
        tier: :scene,
        max_tokens: Config.tier2_max_tokens(),
        session_id: opts[:session_id],
        structured_output: "narration",
        validate: &valid_scene_reply?/1
      )
      |> case do
        {:ok, %{"location_name" => location_name, "narrative" => narrative}}
        when is_binary(location_name) ->
          {:ok, %{location_name: location_name, narrative: narrative}}

        {:ok, map} ->
          {:error, {:invalid_scene, map}}

        error ->
          error
      end
    end
  end

  @doc "A playtest persona's next move (`action`, `option_id`). Persona cost is a bot bucket, not game cost."
  @spec complete_persona(String.t(), String.t(), call_opts()) :: result(map())
  def complete_persona(system, user, opts \\ []) do
    model = tier2_model()

    if mock?(model) do
      {:ok, %{"action" => "I look around and listen.", "option_id" => nil}}
    else
      complete_json(
        model,
        simple_messages(system, user),
        @persona_schema,
        Config.tier2_temperature(),
        tier: :persona,
        max_tokens: @persona_max_tokens,
        session_id: opts[:session_id],
        turn_number: opts[:turn_number]
      )
    end
  end

  @fact_extract_schema %{
    "type" => "object",
    "required" => ["facts"],
    "properties" => %{
      "facts" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "required" => ["about", "kind", "text"],
          "properties" => %{
            "about" => %{"type" => "string"},
            "kind" => %{"type" => "string"},
            "text" => %{"type" => "string"}
          }
        }
      }
    }
  }
  @fact_extract_max_tokens 200

  @doc """
  World agents round 2: new facts and promises read from a finished GM
  narration (`TalesForge.World.Extract`). Purpose `fact_extract`, conv id
  `<session>:facts`, temperature 0.
  """
  @spec complete_fact_extract(String.t(), String.t(), call_opts()) :: result(map())
  def complete_fact_extract(system, user, opts \\ []) do
    model = tier1_model()

    if mock?(model) do
      {:ok, %{"facts" => []}}
    else
      complete_json(model, simple_messages(system, user), @fact_extract_schema, 0.0,
        tier: :fact_extract,
        max_tokens: @fact_extract_max_tokens,
        session_id: opts[:session_id],
        turn_number: opts[:turn_number]
      )
    end
  end

  @doc "The LLM judge's scorecard for a playtest (`scores`, `rationale`); `:criteria` sizes the mock reply."
  @spec complete_scorer(String.t(), String.t(), keyword()) :: result(map())
  def complete_scorer(system, user, opts \\ []) do
    model = tier2_model()

    if mock?(model) do
      {:ok, mock_scorecard(Keyword.get(opts, :criteria, 0))}
    else
      complete_json(model, simple_messages(system, user), @scorer_schema, @scorer_temperature,
        tier: :scorer,
        max_tokens: @scorer_max_tokens,
        session_id: opts[:session_id]
      )
    end
  end

  defp mock_scorecard(criteria) do
    %{
      "scores" =>
        for(n <- 1..criteria//1, do: %{"criterion" => n, "score" => nil, "evidence" => "mock"}),
      "rationale" => "Mock judge: nothing was scored."
    }
  end

  @doc "GM turn. `messages` come from `Prompts.gm_messages/5`; the reply is decoded into a `GMStructuredResponse`."
  @spec complete_turn([map()], PlayerAction.t(), HandlerResult.t(), integer(), call_opts()) ::
          result(GMStructuredResponse.t())
  def complete_turn(
        messages,
        %PlayerAction{} = player_action,
        %HandlerResult{} = handler,
        turn_number,
        opts \\ []
      )
      when is_list(messages) do
    model = tier2_model()

    if mock?(model) do
      {:ok, mock_turn_response(player_action, handler, turn_number)}
    else
      complete_json(model, messages, narration_schema(), Config.tier2_temperature(),
        tier: :tier2,
        max_tokens: Config.tier2_max_tokens() + @gm_notes_max_tokens,
        session_id: opts[:session_id],
        turn_number: turn_number,
        structured_output: "narration",
        validate: &valid_gm_reply?/1
      )
      |> case do
        {:ok, map} -> {:ok, GMStructuredResponse.decode(map)}
        error -> error
      end
    end
  end

  defp valid_gm_reply?(%{"narrative" => narrative}) when is_binary(narrative),
    do: String.trim(narrative) != ""

  defp valid_gm_reply?(_map), do: false

  defp valid_scene_reply?(%{"location_name" => name} = map) when is_binary(name),
    do: String.trim(name) != "" and valid_gm_reply?(map)

  defp valid_scene_reply?(_map), do: false

  defp mock_scene_response(context) do
    location_name = Map.get(context, "location_name", "Unknown")
    blurb = Map.get(context, "location_blurb", "")
    situation = Map.get(context, "situation_lines", []) |> Enum.join("\n")

    narrative =
      [
        blurb,
        situation,
        "\n_Mock GM: set XAI_API_KEY for full scene narration._"
      ]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join("\n\n")

    %{location_name: location_name, narrative: narrative}
  end

  defp mock_turn_response(
         %PlayerAction{} = player_action,
         %HandlerResult{} = _handler,
         turn_number
       ) do
    narrative =
      "**Turn #{turn_number}** — The world reacts to your action.\n\n" <>
        "#{player_action.overall_intent}\n\n" <>
        "_Mock GM: set XAI_API_KEY for full LLM narration._"

    %GMStructuredResponse{narrative: narrative, raw: %{"narrative" => narrative}}
  end

  # Calls with :structured_output (a schema name) use xAI strict json_schema; the
  # schema travels in response_format, not in the prompt. Other calls, and other
  # providers, keep json_object with the schema pasted at the end of the user text.
  #
  # One retry on unparseable JSON or a reply that fails :validate. The retry
  # re-sends the identical messages with a short correction APPENDED, so the
  # cached prefix (system + rules + state) still matches.
  defp complete_json(model, messages, schema, temperature, opts) do
    {messages, opts} = prepare_schema(model, messages, schema, opts)
    validate = Keyword.get(opts, :validate, fn _map -> true end)

    case dispatch_json(model, messages, temperature, opts, validate) do
      {:error, reason} when reason in [:invalid_json, :invalid_reply] ->
        dispatch_json(model, retry_messages(messages), temperature, opts, validate)

      result ->
        result
    end
  end

  defp simple_messages(system, user),
    do: [%{role: "system", content: system}, %{role: "user", content: user}]

  @doc false
  @spec retry_messages([map()]) :: [map()]
  def retry_messages(messages), do: messages ++ [%{role: "user", content: @retry_correction}]

  defp prepare_schema(model, messages, schema, opts) do
    case Keyword.get(opts, :structured_output) do
      name when is_binary(name) ->
        if xai_target?(model) do
          format = %{
            type: "json_schema",
            json_schema: %{name: name, schema: schema, strict: true}
          }

          {messages, Keyword.put(opts, :response_format, format)}
        else
          {paste_schema(messages, schema), opts}
        end

      _ ->
        {paste_schema(messages, schema), opts}
    end
  end

  # json_object fallback: the schema goes at the very end of the last message.
  defp paste_schema(messages, schema) do
    {last, rest} = List.pop_at(messages, -1)

    pasted =
      last.content <>
        "\n\nReturn JSON matching this schema:\n" <> Jason.encode!(schema, pretty: true)

    rest ++ [%{last | content: pasted}]
  end

  defp dispatch_json(model, messages, temperature, opts, validate) do
    with {:ok, raw} <- dispatch(model, messages, temperature, opts),
         {:ok, map} <- parse_json(raw) do
      if validate.(map), do: {:ok, map}, else: {:error, :invalid_reply}
    end
  end

  defp xai_target?(model), do: String.starts_with?(model, "xai/") or provider() == "xai"

  defp dispatch("mock", _messages, _temp, _opts), do: {:error, :mock_model}

  defp dispatch(model, messages, temperature, opts) do
    case AICalls.check_spend_caps(opts[:session_id], purpose(Keyword.get(opts, :tier))) do
      :ok -> request(model, messages, temperature, opts)
      {:error, {kind, limit, spent}} -> spend_capped(model, opts, kind, limit, spent)
    end
  end

  defp spend_capped(model, opts, kind, limit, spent) do
    tier = Keyword.get(opts, :tier, :unknown)

    Logger.warning(
      "llm spend cap hit cap=#{kind} limit_usd=#{usd(limit)} spent_usd=#{usd(spent)} session=#{opts[:session_id]} tier=#{tier} model=#{model}"
    )

    record_call(model, tier, opts, :capped, 0, %{started_at: DateTime.utc_now()})
    {:error, {:spend_cap, kind}}
  end

  defp usd(micro_usd), do: :erlang.float_to_binary(micro_usd / 1_000_000, decimals: 4)

  defp request(model, messages, temperature, opts) do
    started_at = DateTime.utc_now()
    started = System.monotonic_time(:millisecond)
    provider = provider()
    tier = Keyword.get(opts, :tier, :unknown)
    max_tokens = Keyword.get(opts, :max_tokens)

    Logger.info(
      "llm call start tier=#{tier} provider=#{provider} model=#{model} temp=#{temperature} max_tokens=#{max_tokens}"
    )

    result =
      cond do
        xai_target?(model) ->
          call_openai_compatible(model, messages, temperature, xai_base(), Config.xai_api_key(),
            max_tokens: max_tokens,
            headers: [{"x-grok-conv-id", conv_id(opts)}],
            response_format: Keyword.get(opts, :response_format)
          )

        String.starts_with?(model, "gpt-") or provider == "openai" ->
          call_openai_compatible(
            model,
            messages,
            temperature,
            openai_base(),
            Config.openai_api_key(),
            max_tokens: max_tokens
          )

        String.starts_with?(model, "ollama/") ->
          call_ollama(model, messages, temperature)

        true ->
          {:error, {:unsupported_model, model}}
      end

    elapsed = System.monotonic_time(:millisecond) - started
    conv = if xai_target?(model), do: conv_id(opts)
    record_call(model, tier, opts, result, elapsed, %{started_at: started_at, conv_id: conv})

    case result do
      {:ok, content, _usage} ->
        Logger.info(
          "llm call done tier=#{tier} provider=#{provider} model=#{model} duration_ms=#{elapsed} chars=#{String.length(content)}"
        )

        {:ok, content}

      error ->
        error
    end
  end

  defp record_call(model, tier, opts, result, latency_ms, extra) do
    {status, usage} =
      case result do
        {:ok, _content, usage} -> {"ok", usage}
        :capped -> {"capped", %{}}
        _error -> {"error", %{}}
      end

    AICalls.record(%{
      game_session_id: opts[:session_id],
      turn_number: opts[:turn_number],
      purpose: purpose(tier),
      model: model,
      status: status,
      latency_ms: latency_ms,
      usage: usage,
      call_type: "llm",
      started_at: extra[:started_at],
      conv_id: extra[:conv_id]
    })
  end

  defp purpose(:tier1), do: "intent"
  defp purpose(:tier2), do: "gm"
  defp purpose(tier), do: to_string(tier)

  @doc """
  The `x-grok-conv-id` sent with every xAI call.

  xAI keeps its prompt cache per server; requests with the same conversation id
  are routed to the same server. Only the narration calls of a game session
  (scene and GM turns, which share the narrator + rules prefix) use the bare
  session id. Every other call for the session (persona, scorer, intent) gets
  `<session id>:<purpose>`: when a persona call ran on the session id between
  GM turns, the next GM turn reused nothing (cached_tokens 128); with the
  persona on its own id the same sequence reused the narrator + rules prefix
  (measured 2026-10-07).

  A call without a session gets a stable per-purpose id (`tales-forge-<purpose>`)
  rather than none: its prompt still starts with a static prefix worth reusing,
  and the id carries nothing about a player.
  """
  @spec conv_id(keyword()) :: String.t()
  def conv_id(opts) do
    purpose = purpose(Keyword.get(opts, :tier, :unknown))

    case opts[:session_id] do
      id when is_binary(id) and id != "" and purpose in @narration_purposes -> id
      id when is_binary(id) and id != "" and purpose == "fact_extract" -> id <> ":facts"
      id when is_binary(id) and id != "" -> id <> ":" <> purpose
      _ -> "tales-forge-" <> purpose
    end
  end

  defp call_openai_compatible(model, messages, temperature, base_url, api_key, call_opts) do
    if String.trim(api_key) == "" do
      {:error, :missing_api_key}
    else
      clean_model =
        model |> String.replace_prefix("xai/", "") |> String.replace_prefix("openai/", "")

      body =
        %{
          model: clean_model,
          temperature: temperature,
          response_format: call_opts[:response_format] || %{type: "json_object"},
          messages: messages
        }
        |> maybe_put_max_tokens(call_opts[:max_tokens])

      Req.post(
        base_url <> "/chat/completions",
        [
          headers:
            [{"authorization", "Bearer " <> api_key}, {"content-type", "application/json"}] ++
              Keyword.get(call_opts, :headers, []),
          json: body,
          receive_timeout: 120_000,
          retry: false
        ] ++ req_options()
      )
      |> case do
        {:ok,
         %{
           status: 200,
           body: %{"choices" => [%{"message" => %{"content" => content}} | _]} = body
         }} ->
          {:ok, content || "{}", AICalls.usage(body)}

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp call_ollama(model, messages, temperature) do
    clean = String.replace_prefix(model, "ollama/", "")
    base = String.trim_trailing(Config.ollama_api_base(), "/")

    Req.post(
      base <> "/api/chat",
      json: %{
        model: clean,
        stream: false,
        options: %{temperature: temperature},
        messages: messages
      },
      receive_timeout: 120_000,
      retry: false
    )
    |> case do
      {:ok, %{status: 200, body: %{"message" => %{"content" => content}}}} ->
        {:ok, content || "{}", %{}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_json(text) do
    text
    |> strip_fences()
    |> Jason.decode()
    |> case do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_json}
    end
  end

  defp strip_fences(text) do
    text
    |> String.trim()
    |> String.replace(~r/^```(?:json)?\s*/u, "")
    |> String.replace(~r/\s*```$/u, "")
    |> String.trim()
  end

  @doc "Model for small calls (intent, fact extraction): `TIER1_MODEL`, else the first configured provider, else `\"mock\"`."
  @spec tier1_model() :: String.t()
  def tier1_model, do: resolve_tier_model(Config.tier1_model())

  @doc "Model for narration and bots (scene, GM, persona, scorer): `TIER2_MODEL`, else as `tier1_model/0`."
  @spec tier2_model() :: String.t()
  def tier2_model, do: resolve_tier_model(Config.tier2_model())

  @doc "`XAI_MODEL`, unless it is a reasoning model (too slow for turns); then the default xAI model."
  @spec effective_xai_model() :: String.t()
  def effective_xai_model do
    model = Config.xai_model()

    if reasoning_model?(model) do
      Logger.warning(
        "XAI_MODEL #{model} is a reasoning model; using #{Config.default_xai_model()} for game turns"
      )

      Config.default_xai_model()
    else
      model
    end
  end

  defp resolve_tier_model(nil) do
    cond do
      Config.xai_api_key() != "" -> "xai/" <> effective_xai_model()
      Config.openai_api_key() != "" -> "gpt-4o-mini"
      ollama_reachable?() -> "ollama/llama3.2"
      Config.anthropic_api_key() != "" -> "anthropic/claude-3-5-haiku-20241022"
      true -> "mock"
    end
  end

  defp resolve_tier_model(model), do: model

  defp ollama_reachable? do
    if Config.xai_api_key() != "" do
      false
    else
      base = String.trim_trailing(Config.ollama_api_base(), "/")

      # Probe must not use Req's default retries (1s+2s+4s on connection refused).
      case Req.get(base <> "/api/tags", receive_timeout: 1_500, retry: false) do
        {:ok, %{status: 200}} -> true
        _ -> false
      end
    end
  end

  defp mock?("mock"), do: true
  defp mock?(_model), do: provider() == "mock"

  @doc """
  True for reasoning models.

      iex> TalesForge.LLM.reasoning_model?("grok-4-fast-reasoning")
      true
      iex> TalesForge.LLM.reasoning_model?("grok-4-fast-non-reasoning")
      false
  """
  @spec reasoning_model?(String.t()) :: boolean()
  def reasoning_model?(model) do
    lowered = String.downcase(model)

    String.contains?(lowered, "reasoning") and not String.contains?(lowered, "non-reasoning")
  end

  defp maybe_put_max_tokens(body, nil), do: body
  defp maybe_put_max_tokens(body, max_tokens), do: Map.put(body, :max_tokens, max_tokens)

  # Test hook: config :ex_tales_forge, :llm_req_options, plug: {Req.Test, ...}
  defp req_options, do: Application.get_env(:ex_tales_forge, :llm_req_options, [])

  defp xai_base, do: "https://api.x.ai/v1"
  defp openai_base, do: "https://api.openai.com/v1"
end
