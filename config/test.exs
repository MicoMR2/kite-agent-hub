import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Run `Trading.async_record_outcome/1` synchronously in tests so the
# CI corpus row lands before the assertion. In dev/prod the work is
# spawned under `KiteAgentHub.TaskSupervisor` so it does NOT inherit
# the calling worker's `Repo.with_user` connection.
config :kite_agent_hub, :sync_record_outcome, true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :kite_agent_hub, KiteAgentHub.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "kite_agent_hub_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# ObanRepo points at the same test database with the SQL Sandbox
# pool so Oban inline-mode jobs stay inside the test transaction.
config :kite_agent_hub, KiteAgentHub.ObanRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "kite_agent_hub_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :kite_agent_hub, KiteAgentHubWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "CEsrt1MdAtOHadJHlzz/Q/zbieRQKxnjLoSbapGr32XI7WbBUqY4WMyD16OJUGrI",
  server: false

# Run Oban jobs inline during tests (no background DB connections)
config :kite_agent_hub, Oban, testing: :inline

# In test we don't send emails
config :kite_agent_hub, KiteAgentHub.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Invite-only off in test — overridden per-test via Application.put_env when needed.
config :kite_agent_hub, invite_only_signup: false
config :kite_agent_hub, admin_emails: "admin@example.com"

# Shorten the triggers long-poll cap so the empty-queue path doesn't
# block tests for the production 10s default. The default is enforced
# in `triggers_controller.ex`.
config :kite_agent_hub, :triggers_long_poll_ms, 50
