# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :kite_agent_hub, :scopes,
  user: [
    default: true,
    module: KiteAgentHub.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: KiteAgentHub.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :kite_agent_hub,
  ecto_repos: [KiteAgentHub.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :kite_agent_hub, KiteAgentHubWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: KiteAgentHubWeb.ErrorHTML, json: KiteAgentHubWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: KiteAgentHub.PubSub,
  live_view: [signing_salt: "kiNJkYMR"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :kite_agent_hub, KiteAgentHub.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  kite_agent_hub: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  kite_agent_hub: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Oban trade job queue
config :kite_agent_hub, Oban,
  engine: Oban.Engines.Basic,
  repo: KiteAgentHub.Repo,
  queues: [
    trade_execution: 5,
    settlement: 10,
    # PR #108: KiteAttestationWorker runs on its own queue with
    # concurrency: 1 so on-chain attestation jobs are serialized.
    # Each tx needs a unique nonce from RPC.get_transaction_count;
    # parallel jobs all see the same `latest` nonce, sign txs with
    # identical nonces, and only one lands per slot — meaning two
    # of three would silently share a tx hash. Serializing here
    # eliminates the race entirely with no application-level nonce
    # tracking required.
    attestation: 1,
    position_sync: 2,
    maintenance: 1,
    # PR #193: paper-mode executor (OANDA practice + Polymarket paper).
    # Low concurrency — paper orders are lightweight but we want
    # deterministic ordering per agent for simulated fills.
    paper_execution: 3
  ],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       # Prune stale chat messages every 6 hours — keeps at least the last
       # 100 per org, deletes anything older than 24h beyond that.
       {"0 */6 * * *", KiteAgentHub.Workers.MessagePrunerWorker},
       # Poll Alpaca for fill status of open Alpaca trades every minute —
       # closes the loop on the platform-as-broker execution path so
       # filled orders flip to settled and rejected/cancelled orders
       # stop blocking the agent's open-position view.
       {"* * * * *", KiteAgentHub.Workers.AlpacaSettlementWorker},
       # PR #105: every 5 minutes, scan for any settled trades that
       # don't yet have an attestation_tx_hash and enqueue attestation
       # jobs for them. Catches trades that settled before the
       # pipeline existed, attestation jobs that got discarded
       # during the AGENT_PRIVATE_KEY misconfig window (~v112-v117),
       # and any future transient failures. Bounded scan + idempotent
       # downstream worker = safe at any cadence.
       {"*/5 * * * *", KiteAgentHub.Workers.AttestationBackfillWorker},
       # Every 5 minutes, snapshot the QRB edge score for every
       # position in every active org so `/api/v1/edge-scores/history`
       # can surface momentum inflection trends. Bounded rows-per-
       # tick = num_orgs * num_positions, comfortably small.
       {"*/5 * * * *", KiteAgentHub.Workers.EdgeScoreSnapshotWorker},
       # Sweep open trades older than 1h and auto-cancel them. Protects
       # against zombie orders piling up when a broker or downstream
       # settlement path never returns a terminal status — those stuck
       # rows block same-symbol re-entry via wash-trade rules until a
       # human intervenes.
       {"* * * * *", KiteAgentHub.Workers.StuckTradeSweeper},
       # Weekly bootstrap of the Kite Collective Intelligence corpus
       # from public market-data backtests. Synthesizes ~50 outcomes
       # per seed market (top 10 equities + 3 crypto) so new agents
       # have meaningful baseline win-rate insights from day 1.
       # Idempotent on source_trade_hash — re-runs upsert cleanly.
       {"0 4 * * 0", KiteAgentHub.Workers.KciSeederWorker}
     ]}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
