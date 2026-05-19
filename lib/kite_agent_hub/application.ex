defmodule KiteAgentHub.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # ETS-backed positions cache for AlpacaClient. Created before any
    # supervisor child starts so the first AgentRunner tick or
    # TradeExecutionWorker job sees the table. `:public` so every
    # process hits it directly (no GenServer hop); writes go through
    # `AlpacaClient.positions/3` and `invalidate_positions_cache/2`.
    # KAH P1 2026-05-07 surfaced 5 agents × per-tick
    # PortfolioEdgeScorer + N trade attempts × clamp_qty_for_intent
    # each calling `AlpacaClient.positions/3` — that fan-out timed
    # out the `:trade_execution` Oban worker before it could reach
    # `place_order`. The cache collapses the redundant GETs.
    :ets.new(:alpaca_positions_cache, [
      :set,
      :public,
      :named_table,
      read_concurrency: true
    ])

    # Vault balance cache (Passport transparency marker, PR vault-balance-
    # 2026-05-11). Owned by the application root process so it outlives
    # any LiveView mount that races to be the first reader.
    :ets.new(:kah_vault_balance_cache, [
      :set,
      :public,
      :named_table,
      read_concurrency: true
    ])

    children = [
      KiteAgentHubWeb.Telemetry,
      KiteAgentHub.Repo,
      # Dedicated Oban repo. Same DATABASE_URL, isolated connection
      # pool so Oban LISTEN/NOTIFY traffic + per-job state-transition
      # queries never compete with the main app pool — closes the
      # pg_notify-saturation pattern named in DevOps msg 8283. Must
      # start BEFORE the Oban supervisor below.
      KiteAgentHub.ObanRepo,
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
      # PR-I₂ Kalshi live-event-truth cache. ETS-backed, named table
      # owner; the worker writes here and Phase 2 KalshiEdgeScorer
      # reads from here without round-tripping to Kalshi every tick.
      KiteAgentHub.Kite.KalshiLiveDataCache,
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
