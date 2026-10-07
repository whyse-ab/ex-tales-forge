import Config

if config_env() == :dev do
  env_path = Path.expand("../.env", __DIR__)

  if File.exists?(env_path) do
    env_path
    |> then(&Dotenvy.source!([&1, System.get_env()]))
    |> System.put_env()
  end
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/ex_tales_forge start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :ex_tales_forge, TalesForgeWeb.Endpoint, server: true
end

config :ex_tales_forge, TalesForgeWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  if database_url = System.get_env("DATABASE_URL") do
    config :ex_tales_forge, TalesForge.Repo,
      url: database_url,
      stacktrace: true,
      show_sensitive_data_on_connection_error: true,
      pool_size: 10
  end
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :ex_tales_forge, TalesForge.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :ex_tales_forge, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :ex_tales_forge, TalesForgeWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :ex_tales_forge, TalesForgeWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :ex_tales_forge, TalesForgeWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :ex_tales_forge, TalesForge.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #

  # Mail adapter for admin magic links (Resend by default; Postmark also supported).
  mail_adapter = System.get_env("MAIL_ADAPTER") || "resend"

  mailer_config =
    case mail_adapter do
      "postmark" ->
        [
          adapter: Swoosh.Adapters.Postmark,
          api_key: System.get_env("POSTMARK_API_KEY") || System.get_env("MAIL_API_KEY")
        ]

      _ ->
        [
          adapter: Swoosh.Adapters.Resend,
          api_key: System.get_env("RESEND_API_KEY") || System.get_env("MAIL_API_KEY")
        ]
    end

  config :ex_tales_forge, TalesForge.Mailer, mailer_config
end

# Founder admin allowlist (comma-separated emails), for magic links and for
# "Sign in with GitHub" (any verified GitHub email on the list).
# In test, prefer config/test.exs defaults unless ADMIN_EMAILS is explicitly set.
admin_emails_env = System.get_env("ADMIN_EMAILS")

if admin_emails_env || config_env() != :test do
  admin_emails =
    (admin_emails_env || "")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.reject(&(&1 == ""))

  config :ex_tales_forge, :admin_emails, admin_emails
end

config :ex_tales_forge, :github_docs_token, System.get_env("GITHUB_DOCS_TOKEN")

# "Sign in with GitHub" for /admin. Both values are needed, otherwise the button
# is hidden and the routes redirect back to the login page.
# ADMIN_GITHUB_TEAM ("org/team-slug", optional): active members of that team
# get in too; unset = team access off. Membership is checked with
# GITHUB_DOCS_TOKEN, which then needs read access to the org's members.
if config_env() != :test do
  config :ex_tales_forge, :github_oauth,
    client_id: System.get_env("GITHUB_OAUTH_CLIENT_ID"),
    client_secret: System.get_env("GITHUB_OAUTH_CLIENT_SECRET")

  config :ex_tales_forge, :admin_github_team, System.get_env("ADMIN_GITHUB_TEAM")
end

config :ex_tales_forge, :tales_forge_docs_path, System.get_env("TALES_FORGE_DOCS_PATH")

# TypeSafe Jev (persona-affect scoring on playtest). Unset = Jev scoring skipped.
# Key name TYPESAFE_API_KEY; set on tales-forge-playtest only for now.
config :jev,
  api_key: System.get_env("TYPESAFE_API_KEY"),
  model: "jev-1.13.0"

# Admin costs page peer (/admin/costs). Both apps run the same code: whichever
# side has both values set fetches the other side's aggregated AI spend.
# COSTS_PEER_TOKEN (secret, same value on both apps) also turns on this app's
# GET /internal/costs endpoint; unset = the endpoint answers 404.
# COSTS_PEER_URL (config, not a secret): the other app's base URL, e.g.
# https://tales-forge-playtest.fly.dev on production.
# FLY_APP_NAME is set by Fly and names this app on the page.
if config_env() != :test do
  config :ex_tales_forge, :costs_peer,
    url: System.get_env("COSTS_PEER_URL"),
    token: System.get_env("COSTS_PEER_TOKEN")

  config :ex_tales_forge, :app_name, System.get_env("FLY_APP_NAME")
end

# AI spending caps in decimal USD (e.g. "2.50"). Unset or empty = that cap is off,
# except AI_CAP_PERSONA_RUN_USD (persona bot spend per playtest run), which then
# defaults to 0.50; "0" stops those calls. Read by TalesForge.AICalls.check_spend_caps/3.
if config_env() != :test do
  usd_cap = fn name ->
    case String.trim(System.get_env(name, "")) do
      "" ->
        nil

      value ->
        case Float.parse(value) do
          {usd, ""} when usd >= 0 -> round(usd * 1_000_000)
          _ -> raise "#{name} must be a decimal USD amount like 2.50, got: #{inspect(value)}"
        end
    end
  end

  config :ex_tales_forge, :ai_spend_caps,
    session_micro_usd: usd_cap.("AI_CAP_SESSION_USD"),
    day_micro_usd: usd_cap.("AI_CAP_DAY_USD"),
    persona_run_micro_usd: usd_cap.("AI_CAP_PERSONA_RUN_USD")

  # Persona bot runner (TalesForge.Playtest.Runner). Only "true" enables it;
  # set on playtest only, never in production.
  config :ex_tales_forge,
         :playtest_runner_enabled,
         System.get_env("PLAYTEST_RUNNER_ENABLED") == "true"
end

# Existing LLM key (also loaded elsewhere via System.get_env)
# XAI_API_KEY is read by TalesForge.Config / LLM at runtime.
