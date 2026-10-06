# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ex_tales_forge,
  namespace: TalesForge,
  ecto_repos: [TalesForge.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [TalesForge.Authoring, TalesForge.AdminResources]

# Required since Ash 3.33 (EEF-CVE-2026-82752): count string length in codepoints,
# matching Postgres, so max_length really bounds stored values.
config :ash, default_string_length_count: :codepoints

config :ex_tales_forge, TalesForge.Jido,
  max_tasks: 1000,
  agent_pools: []

config :ex_tales_forge, Oban,
  repo: TalesForge.Repo,
  queues: [default: 10, llm: 5, images: 3],
  plugins: [{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}]

# LLM prices in USD per 1M tokens, used when a response carries no billed cost.
# Source: https://docs.x.ai/developers/pricing (fetched 2026-10-06). Prompts at or
# above long_context.threshold tokens are billed at long_context rates for all tokens.
# Models missing here get cost nil and a warning.
config :ex_tales_forge, :llm_prices, %{
  "grok-4.20-0309-non-reasoning" => %{
    input: 1.25,
    cached_input: 0.20,
    output: 2.50,
    long_context: %{threshold: 200_000, input: 2.50, cached_input: 0.40, output: 5.00}
  },
  "grok-4.20-0309-reasoning" => %{
    input: 1.25,
    cached_input: 0.20,
    output: 2.50,
    long_context: %{threshold: 200_000, input: 2.50, cached_input: 0.40, output: 5.00}
  },
  "grok-4.3" => %{
    input: 1.25,
    cached_input: 0.20,
    output: 2.50,
    long_context: %{threshold: 200_000, input: 2.50, cached_input: 0.40, output: 5.00}
  },
  "grok-4.7" => %{
    input: 2.00,
    cached_input: 0.50,
    output: 6.00,
    long_context: %{threshold: 200_000, input: 4.00, cached_input: 1.00, output: 12.00}
  }
}

# Admin costs page (/admin/costs). Edit cost figures HERE, in one place.
# fixed_monthly: one entry per fixed cost. usd is USD per month, or :unknown,
#   which the page shows as "unknown" and leaves out of every total.
#   env: :production, :playtest or :shared; the playtest warning sums :playtest.
# usd_sek: fixed USD->SEK rate with its date and source; update it by hand.
# playtest_warn_usd: warn when playtest's fixed costs plus its projected AI
#   spend for the month exceed this many USD.
config :ex_tales_forge, TalesForge.Costs,
  fixed_monthly: [
    %{
      name: "Fly app tales-forge",
      env: :production,
      usd: 6.95,
      source: "shared-cpu-1x 1 GB, always on; Fly arn list price (docs/environments.md, Costs)"
    },
    %{
      name: "Fly Postgres tales-forge-db",
      env: :production,
      usd: 6.00,
      source:
        "~$6/month, shared-cpu-1x 1 GB (docs/infrastructure.md). docs/environments.md's " <>
          "~$14 production total implies ~$7.10 (1 GB machine $6.95 + $0.15 volume)"
    },
    %{
      name: "Fly app tales-forge-playtest",
      env: :playtest,
      usd: 3.84,
      source: "shared-cpu-1x 512 MB, always on (docs/environments.md, docs/infrastructure.md)"
    },
    %{
      name: "Fly Postgres tales-forge-playtest-db",
      env: :playtest,
      usd: 3.99,
      source: "$3.84 machine + $0.15 1 GB volume (docs/environments.md, docs/infrastructure.md)"
    },
    %{
      name: "PR preview apps",
      env: :shared,
      usd: 0.0,
      source: "Not built yet; ~$1.50/month estimated once built (docs/environments.md)"
    },
    %{
      name: "Resend",
      env: :shared,
      usd: 0.0,
      source: "Not set up yet; free tier when it starts (docs/infrastructure.md)"
    },
    %{
      name: "GitHub whyse-ab (Team)",
      env: :shared,
      usd: 20.0,
      source: "5 seats x $4, from Fredrik 2026-10-06"
    },
    %{
      name: "Domain tales-forge.ai",
      env: :shared,
      usd: :unknown,
      source: "Yearly renewal, price not recorded (docs/infrastructure.md: check registrar)"
    }
  ],
  usd_sek: %{
    rate: 9.9765,
    as_of: ~D[2026-10-06],
    source: "Sveriges Riksbank, USD mid rate (series SEKUSDPMI)"
  },
  playtest_warn_usd: 15.0

# Configure the endpoint
config :ex_tales_forge, TalesForgeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TalesForgeWeb.ErrorHTML, json: TalesForgeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: TalesForge.PubSub,
  live_view: [signing_salt: "5AfZnRXg"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :ex_tales_forge, TalesForge.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  ex_tales_forge: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  ex_tales_forge: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
