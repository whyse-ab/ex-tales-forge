defmodule TalesForge.PrFeed.Versions do
  @moduledoc """
  The commit each app runs, for "on playtest" / "on prod" in the live PR feed.

  - This app: its own `GIT_SHA` (baked into the image by the deploy workflows,
    `TalesForge.Playtest.RunMeta.git_sha/0`).
  - The other app (both apps when local): its `GET /internal/version`
    (`TalesForgeWeb.VersionPeerController`), at the base URL from
    `TalesForge.AppRole.base_url/1`, with the shared `COSTS_PEER_TOKEN` as the
    bearer token (`TalesForge.Costs.Peer.token/0`; no new secret). Unset token,
    a slow or failing peer, or a bad answer: nil, and that app's deploy status
    reads as unknown. 2 s timeout, no retries, no redirects.
  """

  alias TalesForge.AppRole
  alias TalesForge.Costs.Peer
  alias TalesForge.Playtest.RunMeta

  @path "/internal/version"
  @timeout_ms 2_000

  @typedoc "The commit each app runs; nil when unknown."
  @type running :: %{production: String.t() | nil, playtest: String.t() | nil}

  @doc "The commit each app runs (see the moduledoc)."
  @spec running() :: running()
  def running do
    role = AppRole.role()
    %{production: sha(:production, role), playtest: sha(:playtest, role)}
  end

  defp sha(app, app), do: RunMeta.git_sha()
  defp sha(app, _role), do: fetch(app)

  @doc "The commit `app` reports at its `#{@path}`, or nil."
  @spec fetch(:production | :playtest) :: String.t() | nil
  def fetch(app) do
    case Peer.token() do
      nil -> nil
      token -> request(String.trim_trailing(AppRole.base_url(app), "/") <> @path, token)
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
           ] ++ Application.get_env(:ex_tales_forge, :version_peer_req_options, [])
         ) do
      {:ok, %Req.Response{status: 200, body: %{"git_sha" => sha}}} -> valid_sha(sha)
      _other -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  `sha` when it looks like a git commit sha (7 to 40 hex characters), else nil.

      iex> TalesForge.PrFeed.Versions.valid_sha("702CF6F")
      "702cf6f"
      iex> TalesForge.PrFeed.Versions.valid_sha("unknown")
      nil
  """
  @spec valid_sha(term()) :: String.t() | nil
  def valid_sha(sha) when is_binary(sha) do
    sha = sha |> String.trim() |> String.downcase()
    if Regex.match?(~r/\A[0-9a-f]{7,40}\z/, sha), do: sha
  end

  def valid_sha(_sha), do: nil
end
