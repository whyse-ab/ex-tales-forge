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

  @scene_schema %{
    "type" => "object",
    "required" => ["location_name", "narrative"],
    "properties" => %{
      "location_name" => %{"type" => "string"},
      "narrative" => %{"type" => "string"}
    }
  }

  @gm_schema %{
    "type" => "object",
    "required" => ["narrative"],
    "properties" => %{
      "narrative" => %{"type" => "string"},
      "state_updates" => %{"type" => "array"},
      "npc_memory_updates" => %{"type" => "array"},
      "overlay_deltas" => %{"type" => "object"},
      "context_summary" => %{"type" => ["string", "null"]}
    }
  }

  def provider, do: Config.llm_provider()

  def llm_source("mock"), do: "mock"
  def llm_source(_), do: "api"

  def complete_intent(system, user, opts \\ []) do
    model = tier1_model()

    if mock?(model) do
      {:error, :mock_intent}
    else
      complete_json(model, system, user, @intent_schema, Config.tier1_temperature(),
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

  def complete_scene(system, user, intent_context, opts \\ []) when is_map(intent_context) do
    model = tier2_model()

    if mock?(model) do
      {:ok, mock_scene_response(intent_context)}
    else
      complete_json(model, system, user, @scene_schema, Config.tier2_temperature(),
        tier: :scene,
        max_tokens: Config.tier2_max_tokens(),
        session_id: opts[:session_id]
      )
      |> case do
        {:ok, %{"location_name" => location_name, "narrative" => narrative}} ->
          {:ok, %{location_name: location_name, narrative: narrative}}

        {:ok, map} ->
          {:error, {:invalid_scene, map}}

        error ->
          error
      end
    end
  end

  def complete_turn(
        system,
        user,
        %PlayerAction{} = player_action,
        %HandlerResult{} = handler,
        turn_number,
        opts \\ []
      ) do
    model = tier2_model()

    if mock?(model) do
      {:ok, mock_turn_response(player_action, handler, turn_number)}
    else
      user_prompt =
        user <>
          "\n\nValidated player action (turn #{turn_number}):\n" <>
          Jason.encode!(PlayerAction.encode(player_action), pretty: true) <>
          "\n\nAction handler result:\n" <>
          Jason.encode!(handler_payload(handler), pretty: true)

      complete_json(model, system, user_prompt, @gm_schema, Config.tier2_temperature(),
        tier: :tier2,
        max_tokens: Config.tier2_max_tokens(),
        session_id: opts[:session_id],
        turn_number: turn_number
      )
      |> case do
        {:ok, map} -> {:ok, GMStructuredResponse.decode(map)}
        error -> error
      end
    end
  end

  defp handler_payload(%HandlerResult{} = handler) do
    %{
      "handler" => handler.handler,
      "skill" => handler.skill,
      "target" => handler.target,
      "notes" => handler.notes
    }
  end

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
    %GMStructuredResponse{
      narrative:
        "**Turn #{turn_number}** — The world reacts to your action.\n\n" <>
          "#{player_action.overall_intent}\n\n" <>
          "_Mock GM: set XAI_API_KEY for full LLM narration._"
    }
  end

  defp complete_json(model, system, user, schema, temperature, opts) do
    user_with_schema =
      user <>
        "\n\nReturn JSON matching this schema:\n" <>
        Jason.encode!(schema, pretty: true)

    with {:ok, raw} <- dispatch(model, system, user_with_schema, temperature, opts),
         {:ok, map} <- parse_json(raw) do
      {:ok, map}
    else
      {:error, :invalid_json} ->
        retry_user =
          "Your previous response was invalid. Return ONLY valid JSON matching the schema.\n\n" <>
            user_with_schema

        with {:ok, raw} <- dispatch(model, system, retry_user, temperature, opts),
             {:ok, map} <- parse_json(raw) do
          {:ok, map}
        end

      error ->
        error
    end
  end

  defp dispatch("mock", _system, _user, _temp, _opts), do: {:error, :mock_model}

  defp dispatch(model, system, user, temperature, opts) do
    started = System.monotonic_time(:millisecond)
    provider = provider()
    tier = Keyword.get(opts, :tier, :unknown)
    max_tokens = Keyword.get(opts, :max_tokens)

    Logger.info(
      "llm call start tier=#{tier} provider=#{provider} model=#{model} temp=#{temperature} max_tokens=#{max_tokens}"
    )

    result =
      cond do
        String.starts_with?(model, "xai/") or provider == "xai" ->
          call_openai_compatible(
            model,
            system,
            user,
            temperature,
            xai_base(),
            Config.xai_api_key(),
            max_tokens
          )

        String.starts_with?(model, "gpt-") or provider == "openai" ->
          call_openai_compatible(
            model,
            system,
            user,
            temperature,
            openai_base(),
            Config.openai_api_key(),
            max_tokens
          )

        String.starts_with?(model, "ollama/") ->
          call_ollama(model, system, user, temperature)

        true ->
          {:error, {:unsupported_model, model}}
      end

    elapsed = System.monotonic_time(:millisecond) - started
    record_call(model, tier, opts, result, elapsed)

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

  defp record_call(model, tier, opts, result, latency_ms) do
    {status, usage} =
      case result do
        {:ok, _content, usage} -> {"ok", usage}
        _error -> {"error", %{}}
      end

    AICalls.record(%{
      game_session_id: opts[:session_id],
      turn_number: opts[:turn_number],
      purpose: purpose(tier),
      model: model,
      status: status,
      latency_ms: latency_ms,
      usage: usage
    })
  end

  defp purpose(:tier1), do: "intent"
  defp purpose(:tier2), do: "gm"
  defp purpose(tier), do: to_string(tier)

  defp call_openai_compatible(model, system, user, temperature, base_url, api_key, max_tokens) do
    if String.trim(api_key) == "" do
      {:error, :missing_api_key}
    else
      clean_model =
        model |> String.replace_prefix("xai/", "") |> String.replace_prefix("openai/", "")

      body =
        %{
          model: clean_model,
          temperature: temperature,
          response_format: %{type: "json_object"},
          messages: [
            %{role: "system", content: system},
            %{role: "user", content: user}
          ]
        }
        |> maybe_put_max_tokens(max_tokens)

      Req.post(
        base_url <> "/chat/completions",
        [
          headers: [{"authorization", "Bearer " <> api_key}, {"content-type", "application/json"}],
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

  defp call_ollama(model, system, user, temperature) do
    clean = String.replace_prefix(model, "ollama/", "")
    base = String.trim_trailing(Config.ollama_api_base(), "/")

    Req.post(
      base <> "/api/chat",
      json: %{
        model: clean,
        stream: false,
        options: %{temperature: temperature},
        messages: [
          %{role: "system", content: system},
          %{role: "user", content: user}
        ]
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

  def tier1_model, do: resolve_tier_model(Config.tier1_model())
  def tier2_model, do: resolve_tier_model(Config.tier2_model())

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
