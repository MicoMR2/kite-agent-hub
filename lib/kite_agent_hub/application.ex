defmodule KiteAgentHub.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      KiteAgentHubWeb.Telemetry,
      KiteAgentHub.Repo,
      {DNSCluster, query: Application.get_env(:kite_agent_hub, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: KiteAgentHub.PubSub},
      # Start a worker by calling: KiteAgentHub.Worker.start_link(arg)
      # {KiteAgentHub.Worker, arg},
      # Start to serve requests, typically the last entry
      KiteAgentHubWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: KiteAgentHub.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KiteAgentHubWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
