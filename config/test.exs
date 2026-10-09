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

# Sign-in: GitHub team members only. Tests sign in with ConnCase.log_in_admin/2
# (session + cached team membership); the OAuth button is off unless a test turns
# it on, and GitHub HTTP goes to Req.Test stubs.
config :ex_tales_forge, :github_oauth, client_id: nil, client_secret: nil
config :ex_tales_forge, :admin_github_team, "whyse-ab/tales-forge"
config :ex_tales_forge, :github_req_options, plug: {Req.Test, TalesForge.AdminAuth.GitHub}

# Survey definitions: GitHub HTTP goes to Req.Test stubs; without a token the
# snapshot in priv/surveys is used.
config :ex_tales_forge, :survey_req_options, plug: {Req.Test, TalesForge.Survey.Source}

# LLM HTTP goes to Req.Test stubs (tests that switch LLM_PROVIDER away from mock).
config :ex_tales_forge, :llm_req_options, plug: {Req.Test, TalesForge.LLM}

# Admin costs page peer HTTP goes to Req.Test stubs; the peer URL/token are
# unset unless a test puts them.
config :ex_tales_forge, :costs_peer_req_options, plug: {Req.Test, TalesForge.Costs.Peer}

# Live PR feed (/team): no polling in tests and no token; GitHub and the
# other app's /internal/version go to Req.Test stubs. Tests that need a token
# put :pr_feed_token and call TalesForge.PrFeed.Poller.poll/2 themselves.
config :ex_tales_forge, TalesForge.PrFeed, poll: false
config :ex_tales_forge, :pr_feed_token, nil
config :ex_tales_forge, :pr_feed_req_options, plug: {Req.Test, TalesForge.PrFeed.GitHub}
config :ex_tales_forge, :version_peer_req_options, plug: {Req.Test, TalesForge.PrFeed.Versions}

# Docs viewer images from GitHub go to Req.Test stubs (TalesForge.Collab.Files).
config :ex_tales_forge, :docs_req_options, plug: {Req.Test, TalesForge.Collab.Files}

# Jev HTTP goes to Req.Test stubs; no real TypeSafe calls in CI.
# Jev HTTP goes to Req.Test when a test sets :api_key; default nil so Scorer
# keeps using the LLM stub unless a Jev test opts in.
config :jev,
  api_key: nil,
  model: "jev-1.13.0",
  req_options: [plug: {Req.Test, Jev.HTTP}, retry_delay: 0]

# Jev intent (TalesForge.IntentJev): the named :intent endpoint without a key, so
# no test reaches TypeSafe; a test that needs it puts a key with
# Application.put_env/3 and stubs Jev.HTTP with Req.Test. INTENT_JEV is off
# unless a test sets :intent_jev.
config :jev,
  endpoints: [intent: [base_url: "https://api.typesafe.ai", api_key: nil, model: "jev-1.13.0"]]

# The shadow Jev read runs inline in tests (async in dev and prod), so the
# sandbox owns its queries and tests can assert on its ai_calls row.
config :ex_tales_forge, :intent_jev_shadow, :sync
