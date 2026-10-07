defmodule TalesForge.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_tales_forge,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      # Coding standards (tales-forge-docs docs/coding-standards.md): Dialyzer,
      # ExDoc and test coverage. CI runs all of them.
      dialyzer: dialyzer(),
      name: "Tales Forge",
      source_url: "https://github.com/whyse-ab/ex-tales-forge",
      docs: docs(),
      test_coverage: test_coverage(),
      releases: [
        ex_tales_forge: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent]
        ]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {TalesForge.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.8"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:dotenvy, "~> 1.0"},
      {:yaml_elixir, "~> 2.12"},
      {:mdex, "~> 0.14"},
      {:req, "~> 0.7", override: true},
      {:jev, "~> 0.2"},
      {:assent, "~> 0.3.1"},
      {:jido, "~> 2.3"},
      {:jido_ai, "~> 2.2"},
      {:time_zone_info, "~> 0.7"},
      {:oban, "~> 2.23"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # Not dev-only: the Docker builder (MIX_ENV=prod) runs `mix docs` for
      # /admin/code-docs. runtime: false keeps it out of the release itself.
      {:ex_doc, "~> 0.38", runtime: false},

      # Ash for Phase 2 authoring layer (pre-play content only)
      {:ash, "~> 3.0"},
      {:ash_postgres, "~> 2.0"},
      {:ash_phoenix, "~> 2.0"},
      {:igniter, "~> 0.6", only: [:dev, :test]}
    ]
  end

  # Dialyzer: PLTs live in priv/plts (cached in CI). Known warnings in legacy
  # code are listed in .dialyzer_ignore.exs; new code must add none.
  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      plt_add_apps: [:mix, :ex_unit],
      ignore_warnings: ".dialyzer_ignore.exs",
      list_unused_filters: true
    ]
  end

  # `mix docs` builds the browsable docs site into doc/.
  defp docs do
    [
      main: "readme",
      extras: ["README.md", "AGENTS.md"],
      # The guides link to repo files that are not part of the docs site.
      skip_undefined_reference_warnings_on: ["README.md", "AGENTS.md"],
      groups_for_modules: [
        Game: ~r/^TalesForge\.Game\./,
        "World agents": [TalesForge.World, ~r/^TalesForge\.World\./],
        "LLM and AI calls": [TalesForge.LLM, ~r/^TalesForge\.AICalls/],
        Playtest: ~r/^TalesForge\.Playtest/,
        Web: ~r/^TalesForgeWeb/
      ]
    ]
  end

  # `mix test --cover`: fails below the threshold (raise it as coverage grows).
  defp test_coverage do
    [summary: [threshold: 72]]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind ex_tales_forge", "esbuild ex_tales_forge"],
      "assets.deploy": [
        "tailwind ex_tales_forge --minify",
        "esbuild ex_tales_forge --minify",
        "phx.digest"
      ],
      "format.check": ["format --check-formatted"],
      quality: ["format.check", "credo --strict"],
      # Project warnings only (not Hex deps). Reprints even if already compiled.
      warnings: ["compile --force --all-warnings --warnings-as-errors"],
      # Same checks as CI (tales-forge-docs docs/coding-standards.md).
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "quality",
        "test --cover --warnings-as-errors",
        "docs --warnings-as-errors",
        "dialyzer"
      ],
      "dev.check": ["compile", "dev.check"],
      "e2e.smoke": ["compile", "e2e.smoke"],
      "tales.import_pack": ["tales.import_pack"],
      "tales.sync_docs": ["tales.sync_docs"]
    ]
  end
end
