defmodule TalesForge.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TalesForgeWeb.Telemetry,
      TalesForge.Repo,
      {Oban, Application.fetch_env!(:ex_tales_forge, Oban)},
      TalesForge.Jido,
      {Registry, keys: :unique, name: TalesForge.World.Registry},
      {DynamicSupervisor, name: TalesForge.World.Supervisor, strategy: :one_for_one},
      TalesForge.NPCRecovery,
      {DNSCluster, query: Application.get_env(:ex_tales_forge, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: TalesForge.PubSub},
      {Task.Supervisor, name: TalesForge.Playtest.Supervisor},
      {Task.Supervisor, name: TalesForge.Playtest.SeriesSupervisor},
      TalesForge.AdminAuth.MembershipCache,
      TalesForgeWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TalesForge.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TalesForgeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
