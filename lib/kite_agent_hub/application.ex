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
      {Oban, Application.fetch_env!(:kite_agent_hub, Oban)},
      {Registry, keys: :unique, name: KiteAgentHub.AgentRegistry},
      KiteAgentHub.Api.RateLimiter,
      # Task supervisor for fire-and-forget side effects that must
      # NOT inherit the caller's Repo connection — see
      # `KiteAgentHub.Trading.async_record_outcome/1`.
      {Task.Supervisor, name: KiteAgentHub.TaskSupervisor},
      # In-memory ring-buffer log — must start before AgentRunnerSupervisor
      # so runners can push entries from their first tick.
      KiteAgentHub.Kite.AgentLog,
      # Alpaca WebSocket streaming supervisor — starts feeds on demand.
      # No feeds are started at boot; call AlpacaStreamSupervisor.start_feed/3
      # from the dashboard or a background task after resolving credentials.
      KiteAgentHub.TradingPlatforms.AlpacaStreamSupervisor,
      # Per-symbol ring buffer of recent sanitized news headlines.
      # Subscribes to the Alpaca news PubSub topic on init; readers
      # query via `KiteAgentHub.News.Buffer.recent/1`.
      KiteAgentHub.News.Buffer,
      KiteAgentHub.Kite.AgentRunnerSupervisor,
      KiteAgentHubWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: KiteAgentHub.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      KiteAgentHub.Kite.AgentRunnerSupervisor.restart_active_agents()
      # Diagnostic Telemetry: log any Ecto query whose total time
      # (queue + query + decode) exceeds 100ms so we can name the
      # holder behind the recurring DB-pool burst pattern.
      KiteAgentHub.Diagnostics.SlowQueryLogger.attach()
      {:ok, pid}
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KiteAgentHubWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
