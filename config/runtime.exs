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

  # Mail adapter (Resend by default; Postmark also supported). Nothing sends mail
  # since the admin magic links were removed on 2026-10-07.
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

config :ex_tales_forge, :github_docs_token, System.get_env("GITHUB_DOCS_TOKEN")

# "Sign in with GitHub", the only login; every page needs it. Both OAuth values
# are needed, otherwise the button is hidden and nobody can sign in.
# ADMIN_GITHUB_TEAM ("org/team-slug", e.g. whyse-ab/tales-forge): only active
# members of that team get in; unset = nobody gets in. Membership is checked with
# GITHUB_DOCS_TOKEN, which needs read access to the org's members. The OAuth
# app's callback URL must be https://$PHX_HOST/admin/auth/github/callback.
if config_env() != :test do
  config :ex_tales_forge, :github_oauth,
    client_id: System.get_env("GITHUB_OAUTH_CLIENT_ID"),
    client_secret: System.get_env("GITHUB_OAUTH_CLIENT_SECRET")

  config :ex_tales_forge, :admin_github_team, System.get_env("ADMIN_GITHUB_TEAM")
end

config :ex_tales_forge, :tales_forge_docs_path, System.get_env("TALES_FORGE_DOCS_PATH")

# TypeSafe Jev (persona-affect scoring on playtest). Unset = Jev scoring skipped.
# Key name TYPESAFE_API_KEY; set on tales-forge-playtest only for now.
# Not read in test: config/test.exs sets api_key: nil and each test that needs a
# key puts one with Application.put_env/3, so a key exported in the shell never
# changes test results. The app reads the key only from this config, never from
# the environment at call time.
config :jev, model: "jev-1.13.0"

if config_env() != :test do
  config :jev, api_key: System.get_env("TYPESAFE_API_KEY")
end

# Player intent as one Jev call (TalesForge.IntentJev). Config, not secrets.
# INTENT_JEV: off (default) | shadow | on, fixed per new default-variant session.
# The key is TYPESAFE_INTENT_API_KEY (a secret; each Fly app has its own), on the
# named Jev endpoint :intent, which inherits neither the TypeSafe key nor the
# price, so both are set here. Not read in test (config/test.exs).
if config_env() != :test do
  intent_float = fn name, default ->
    case String.trim(System.get_env(name, "")) do
      "" ->
        default

      value ->
        case Float.parse(value) do
          {c, ""} when c >= 0 and c <= 1 -> c
          _ -> raise "#{name} must be a number from 0 to 1 like 0.70, got: #{inspect(value)}"
        end
    end
  end

  intent_jev =
    case System.get_env("INTENT_JEV", "off") |> String.trim() |> String.downcase() do
      mode when mode in ["", "off"] -> :off
      "shadow" -> :shadow
      "on" -> :on
      other -> raise "INTENT_JEV must be off, shadow or on, got: #{inspect(other)}"
    end

  intent_timeout =
    case Integer.parse(String.trim(System.get_env("INTENT_JEV_TIMEOUT_MS", "1500"))) do
      {ms, ""} when ms > 0 -> ms
      _ -> raise "INTENT_JEV_TIMEOUT_MS must be a positive integer (milliseconds)"
    end

  config :ex_tales_forge,
    intent_jev: intent_jev,
    intent_act_min_confidence: intent_float.("INTENT_ACT_MIN_CONFIDENCE", 0.70),
    intent_ask_below_confidence: intent_float.("INTENT_ASK_BELOW_CONFIDENCE", 0.45),
    intent_jev_timeout_ms: intent_timeout,
    player_quote_min_benign_confidence: intent_float.("PLAYER_QUOTE_MIN_BENIGN_CONFIDENCE", 0.90)

  config :jev,
    endpoints: [
      intent: [
        base_url: "https://api.typesafe.ai",
        api_key: System.get_env("TYPESAFE_INTENT_API_KEY"),
        model: "jev-1.13.0",
        usd_per_million_input: 0.042
      ]
    ]
end

# Admin costs page (/admin/costs). Production's page reads playtest's
# playtest-run AI spend live from playtest's GET /internal/costs; the URL is
# playtest's base URL in config :ex_tales_forge, TalesForge.AppRole (config.exs).
# COSTS_PEER_TOKEN (secret, same value on both apps) is the bearer token: it turns
# on the endpoint on playtest and lets production call it. Unset = the endpoint
# answers 404 and production's Playtest section says "not configured".
# FLY_APP_NAME is set by Fly: it names this app and decides its role (AppRole).
if config_env() != :test do
  config :ex_tales_forge, :costs_peer, token: System.get_env("COSTS_PEER_TOKEN")

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
