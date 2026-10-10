defmodule TalesForge.Board.GitHubApp do
  @moduledoc """
  The GitHub App the idea board commits the decision log with (decision
  2026-10-10: an App, not a personal token). Config `:github_app` from
  GITHUB_APP_ID, GITHUB_APP_INSTALLATION_ID and GITHUB_APP_PRIVATE_KEY (PEM;
  literal `\\n` allowed). The App needs Contents: read and write on
  whyse-ab/tales-forge-docs only.

  `token/0` signs a short-lived RS256 JWT as the App and exchanges it for an
  installation token (valid about an hour), fetched fresh per commit.
  """

  @api "https://api.github.com"

  @typedoc "The App's settings."
  @type config :: %{app_id: String.t(), installation_id: String.t(), private_key: String.t()}

  @doc "The App's settings, or nil when any of the three is missing."
  @spec config() :: config() | nil
  def config do
    c = Application.get_env(:ex_tales_forge, :github_app, [])

    with id when is_binary(id) and id != "" <- c[:app_id],
         inst when is_binary(inst) and inst != "" <- c[:installation_id],
         key when is_binary(key) and key != "" <- c[:private_key] do
      %{
        app_id: String.trim(id),
        installation_id: String.trim(inst),
        private_key: String.replace(key, "\\n", "\n")
      }
    else
      _ -> nil
    end
  end

  @doc "A JWT for the App (RS256, valid 9 minutes, backdated 60 s for clock drift)."
  @spec jwt(config(), integer()) :: String.t()
  def jwt(%{app_id: app_id, private_key: pem}, now \\ System.system_time(:second)) do
    [entry | _] = :public_key.pem_decode(pem)
    key = :public_key.pem_entry_decode(entry)
    header = b64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}))
    claims = b64(Jason.encode!(%{"iat" => now - 60, "exp" => now + 540, "iss" => app_id}))
    data = header <> "." <> claims
    data <> "." <> b64(:public_key.sign(data, :sha256, key))
  end

  @doc "An installation token, or `{:error, reason}` (also when the App isn't configured)."
  @spec token() :: {:ok, String.t()} | {:error, term()}
  def token do
    case config() do
      nil ->
        {:error, :not_configured}

      config ->
        case Req.post(
               "#{@api}/app/installations/#{config.installation_id}/access_tokens",
               [headers: headers(jwt(config)), retry: false] ++ req_options()
             ) do
          {:ok, %{status: 201, body: %{"token" => token}}} -> {:ok, token}
          {:ok, %{status: status}} -> {:error, {:token, status}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc "The JSON headers for the GitHub API with a bearer `token`."
  @spec headers(String.t()) :: [{String.t(), String.t()}]
  def headers(token) do
    [
      {"authorization", "Bearer " <> token},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"},
      {"user-agent", "tales-forge-idea-board"}
    ]
  end

  @doc "Extra Req options (config `:board_req_options`; tests stub GitHub there)."
  @spec req_options() :: keyword()
  def req_options, do: Application.get_env(:ex_tales_forge, :board_req_options, [])

  @doc "The API base URL."
  @spec api() :: String.t()
  def api, do: @api

  defp b64(data), do: Base.url_encode64(data, padding: false)
end
