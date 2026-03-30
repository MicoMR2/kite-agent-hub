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
    position_sync: 2
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
