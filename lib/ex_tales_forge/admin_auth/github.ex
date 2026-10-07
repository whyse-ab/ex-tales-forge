defmodule TalesForge.AdminAuth.GitHub do
  @moduledoc """
  "Sign in with GitHub", the app's only login (OAuth web flow via Assent).

  A GitHub user gets in only when ADMIN_GITHUB_TEAM (`org/team-slug`, e.g.
  `whyse-ab/tales-forge`) is set and they have an *active* membership in that
  team (pending invites don't count). With the team unset nobody gets in.

  The user's OAuth access token is only used during the callback and is never
  stored. Team membership is checked, at login and on every later recheck,
  with the server's GITHUB_DOCS_TOKEN (needs read access to org members) and
  cached for a few minutes in `TalesForge.AdminAuth.MembershipCache`.
  """

  require Logger

  alias Assent.Strategy.Github, as: Strategy
  alias TalesForge.AdminAuth
  alias TalesForge.AdminAuth.MembershipCache

  @callback_path "/admin/auth/github/callback"
  @scope "read:org user:email"
  @api "https://api.github.com"
  @default_ttl_ms :timer.minutes(5)
  @error_ttl_ms :timer.seconds(30)

  def callback_path, do: @callback_path

  @doc "True when both GITHUB_OAUTH_CLIENT_ID and GITHUB_OAUTH_CLIENT_SECRET are set."
  def enabled? do
    oauth = Application.get_env(:ex_tales_forge, :github_oauth, [])
    present?(oauth[:client_id]) and present?(oauth[:client_secret])
  end

  @doc "Configured ADMIN_GITHUB_TEAM as `{org, slug}`, or nil (team access off)."
  def team do
    with value when is_binary(value) <- Application.get_env(:ex_tales_forge, :admin_github_team),
         [org, slug] <- value |> String.trim() |> String.split("/", trim: true),
         true <- present?(org) and present?(slug) do
      {org, slug}
    else
      _ -> nil
    end
  end

  @doc "Starts the flow: `{:ok, %{url: url, state: state}}`; keep `state` in the session."
  def authorize_url do
    case Strategy.authorize_url(assent_config()) do
      {:ok, %{url: url, session_params: %{state: state}}} -> {:ok, %{url: url, state: state}}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Handles the callback. Returns `{:ok, %{login: login, email: email}}` for an
  allowed user, `{:error, {:not_allowed, login}}` for a valid GitHub user who
  isn't allowed, or `{:error, reason}` (bad/missing state, GitHub errors, ...).
  """
  def callback(params, state) when is_binary(state) and state != "" do
    config = Keyword.put(assent_config(), :session_params, %{state: state})

    with {:ok, %{user: user, token: token}} <- Strategy.callback(config, params),
         login when is_binary(login) <- user["preferred_username"] || {:error, :no_login},
         {:ok, emails} <- verified_emails(config, token) do
      authorize(login, emails)
    end
  end

  def callback(_params, _state), do: {:error, :missing_state}

  # Team membership is the only gate. The email (primary verified one first) is
  # just the display identity, e.g. on decision comments.
  defp authorize(login, emails) do
    if team_member?(login, fresh: true) do
      email = List.first(emails) || "#{login}@users.noreply.github.com"
      {:ok, %{login: login, email: AdminAuth.normalize(email)}}
    else
      {:error, {:not_allowed, login}}
    end
  end

  # All verified emails, primary first. (Assent's GitHub strategy only
  # returns the primary one.)
  defp verified_emails(config, token) do
    config = Keyword.merge(Strategy.default_config(config), config)

    case Assent.Strategy.OAuth2.request(config, token, :get, "/user/emails") do
      {:ok, %{body: emails}} when is_list(emails) ->
        {:ok,
         emails
         |> Enum.filter(&(&1["verified"] == true and is_binary(&1["email"])))
         |> Enum.sort_by(&(&1["primary"] != true))
         |> Enum.map(& &1["email"])}

      {:ok, _} ->
        {:error, :unexpected_emails_response}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Active member of ADMIN_GITHUB_TEAM? False when team access is off. Results
  are cached (#{div(@default_ttl_ms, 60_000)} min; errors #{div(@error_ttl_ms, 1000)} s);
  `fresh: true` skips the cached value (used at login).
  """
  def team_member?(login, opts \\ [])

  def team_member?(login, opts) when is_binary(login) and login != "" do
    case team() do
      nil -> false
      {org, slug} -> cached_membership(org, slug, login, opts[:fresh])
    end
  end

  def team_member?(_login, _opts), do: false

  defp cached_membership(org, slug, login, fresh?) do
    key = {String.downcase(org), String.downcase(slug), String.downcase(login)}

    case if(fresh?, do: :miss, else: MembershipCache.get(key)) do
      {:ok, member?} ->
        member?

      :miss ->
        {member?, ttl} = fetch_membership(org, slug, login)
        MembershipCache.put(key, member?, ttl)
    end
  end

  defp fetch_membership(org, slug, login) do
    case Application.get_env(:ex_tales_forge, :github_docs_token) do
      token when is_binary(token) and token != "" ->
        path = "/orgs/#{seg(org)}/teams/#{seg(slug)}/memberships/#{seg(login)}"

        case Req.get(api_req(token), url: path) do
          {:ok, %{status: 200, body: %{"state" => "active"}}} ->
            {true, ttl()}

          {:ok, %{status: status}} when status in [200, 404] ->
            {false, ttl()}

          {:ok, %{status: status}} ->
            Logger.warning(
              "GitHub team check #{org}/#{slug} for #{login} failed: HTTP #{status} " <>
                "(does GITHUB_DOCS_TOKEN have read access to #{org} members?)"
            )

            {false, @error_ttl_ms}

          {:error, error} ->
            Logger.warning("GitHub team check failed: #{Exception.message(error)}")
            {false, @error_ttl_ms}
        end

      _ ->
        Logger.warning(
          "ADMIN_GITHUB_TEAM is set but GITHUB_DOCS_TOKEN is not; team access denied"
        )

        {false, @error_ttl_ms}
    end
  end

  defp api_req(token) do
    Req.new(
      [
        base_url: @api,
        headers: [
          {"authorization", "Bearer #{token}"},
          {"accept", "application/vnd.github+json"},
          {"x-github-api-version", "2022-11-28"}
        ],
        retry: false,
        receive_timeout: 5_000
      ] ++ req_options()
    )
  end

  defp assent_config do
    oauth = Application.get_env(:ex_tales_forge, :github_oauth, [])

    [
      client_id: oauth[:client_id],
      client_secret: oauth[:client_secret],
      redirect_uri: TalesForgeWeb.Endpoint.url() <> @callback_path,
      authorization_params: [scope: @scope],
      http_adapter:
        {Assent.HTTPAdapter.Req, [retry: false, receive_timeout: 10_000] ++ req_options()}
    ]
  end

  # Test hook: config :ex_tales_forge, :github_req_options, plug: {Req.Test, ...}
  defp req_options, do: Application.get_env(:ex_tales_forge, :github_req_options, [])

  defp ttl, do: Application.get_env(:ex_tales_forge, :github_membership_ttl_ms, @default_ttl_ms)

  defp seg(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
