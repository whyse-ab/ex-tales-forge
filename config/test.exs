import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :ex_tales_forge, TalesForge.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "ex_tales_forge_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ex_tales_forge, TalesForgeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "ET2hr/KN5DSiR5bbxUGrLNXfzePQsiSsvuV5aOd4vYTc97eVauclD0IR1TdAJyY6",
  server: false

# In test we don't send emails
config :ex_tales_forge, TalesForge.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

config :ex_tales_forge, Oban, testing: :inline, peer: false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :ex_tales_forge, :admin_emails, ["founder@example.com", "other@example.com"]

# Bypass nothing — tests log in via session helper.

# GitHub admin sign-in: off unless a test turns it on; HTTP goes to Req.Test stubs.
config :ex_tales_forge, :github_oauth, client_id: nil, client_secret: nil
config :ex_tales_forge, :admin_github_team, nil
config :ex_tales_forge, :github_req_options, plug: {Req.Test, TalesForge.AdminAuth.GitHub}

# LLM HTTP goes to Req.Test stubs (tests that switch LLM_PROVIDER away from mock).
config :ex_tales_forge, :llm_req_options, plug: {Req.Test, TalesForge.LLM}

# Admin costs page peer HTTP goes to Req.Test stubs; the peer URL/token are
# unset unless a test puts them.
config :ex_tales_forge, :costs_peer_req_options, plug: {Req.Test, TalesForge.Costs.Peer}

# Jev HTTP goes to Req.Test stubs; no real TypeSafe calls in CI.
# Jev HTTP goes to Req.Test when a test sets :api_key; default nil so Scorer
# keeps using the LLM stub unless a Jev test opts in.
config :jev,
  api_key: nil,
  model: "jev-1.13.0",
  req_options: [plug: {Req.Test, Jev.HTTP}, retry_delay: 0]
