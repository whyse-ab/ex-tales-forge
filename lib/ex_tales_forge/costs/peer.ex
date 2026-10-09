defmodule TalesForge.Costs.Peer do
  @moduledoc """
  Playtest's AI spend for production's admin costs page, read live from the
  playtest app's `GET /internal/costs` (`TalesForgeWeb.CostsPeerController`)
  with the shared bearer token. Nothing is copied or stored on production.

  - URL: playtest's base URL from `TalesForge.AppRole.base_url/1` (config
    `TalesForge.AppRole` in `config/config.exs`, the one place for both URLs).
  - Token: the Fly secret `COSTS_PEER_TOKEN`, the same value on both apps
    (config `:costs_peer`, `config/runtime.exs`). Unset: the Playtest section
    says "not configured" and nothing is fetched.
  - Short timeout (2 s), no retries and no redirects: if playtest is
    down, production's page still renders and says "playtest unavailable".
  """

  alias TalesForge.AppRole
  alias TalesForge.Costs.PlaytestRuns

  @path "/internal/costs"
  @timeout_ms 2_000

  @typedoc "Why playtest's numbers are not on the page."
  @type error ::
          :not_configured | :unreachable | :bad_response | {:http_status, non_neg_integer()}

  @doc "The shared token, or nil when unset or blank (then the endpoint is off)."
  @spec token() :: String.t() | nil
  def token, do: blank_to_nil(Application.get_env(:ex_tales_forge, :costs_peer, [])[:token])

  @doc "True when production can ask playtest (the shared token is set)."
  @spec configured?() :: boolean()
  def configured?, do: token() != nil

  @doc "The URL production fetches: playtest's base URL plus `#{@path}`."
  @spec url() :: String.t()
  def url, do: String.trim_trailing(AppRole.base_url(:playtest), "/") <> @path

  @doc "The fetch timeout in milliseconds."
  @spec timeout_ms() :: pos_integer()
  def timeout_ms, do: @timeout_ms

  @doc """
  Fetches and validates playtest's summary (`TalesForge.Costs.PlaytestRuns`).
  Returns `{:ok, summary}`, `{:error, :not_configured}` (no token), or
  `{:error, reason}` with reason `{:http_status, status}`, `:bad_response` or
  `:unreachable`. Never raises.
  """
  @spec fetch() :: {:ok, PlaytestRuns.summary()} | {:error, error()}
  def fetch do
    case token() do
      nil -> {:error, :not_configured}
      token -> request(url(), token)
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
        case PlaytestRuns.normalize(body) do
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
