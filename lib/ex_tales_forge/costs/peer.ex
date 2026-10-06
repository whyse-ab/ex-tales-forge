defmodule TalesForge.Costs.Peer do
  @moduledoc """
  The other environment's AI spend for the admin costs page, fetched from its
  `GET /internal/costs` with the shared bearer token.

  Configured in `config/runtime.exs` from `COSTS_PEER_URL` (the peer's base URL)
  and `COSTS_PEER_TOKEN` (also guards this app's own endpoint). Both apps run
  the same code, so whichever side has both set fetches the other.
  """

  alias TalesForge.Costs

  @path "/internal/costs"
  @timeout_ms 3_000

  @doc "The shared token, or nil when unset or blank (then the endpoint is off)."
  def token, do: blank_to_nil(config()[:token])

  @doc "The peer's base URL, or nil when unset or blank."
  def url, do: blank_to_nil(config()[:url])

  @doc """
  Fetches and validates the peer's summary. Returns `{:ok, summary}`,
  `{:error, :not_configured}` (URL or token missing), or `{:error, reason}` with
  reason `{:http_status, status}`, `:bad_response` or `:unreachable`. Never raises.
  """
  def fetch do
    with {:url, base} when is_binary(base) <- {:url, url()},
         {:token, token} when is_binary(token) <- {:token, token()} do
      request(String.trim_trailing(base, "/") <> @path, token)
    else
      _ -> {:error, :not_configured}
    end
  end

  defp request(url, token) do
    case Req.get(
           [
             url: url,
             auth: {:bearer, token},
             receive_timeout: @timeout_ms,
             connect_options: [timeout: @timeout_ms],
             retry: false,
             redirect: false
           ] ++ req_options()
         ) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} ->
        case Costs.normalize_summary(body) do
          {:ok, summary} -> {:ok, summary}
          :error -> {:error, :bad_response}
        end

      {:ok, %Req.Response{status: 200}} ->
        {:error, :bad_response}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, _exception} ->
        {:error, :unreachable}
    end
  rescue
    _ -> {:error, :unreachable}
  end

  defp config, do: Application.get_env(:ex_tales_forge, :costs_peer, [])

  # Test hook: config :ex_tales_forge, :costs_peer_req_options, plug: {Req.Test, ...}
  defp req_options, do: Application.get_env(:ex_tales_forge, :costs_peer_req_options, [])

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
