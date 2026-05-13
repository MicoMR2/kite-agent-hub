import Config

# WorkOS AuthKit — read from env in all environments.
#
# LLM provider keys are no longer read at app scope: each org
# supplies its own key via the encrypted credentials vault
# (Anthropic / OpenAI) via the encrypted credentials vault. The previous
# shared `anthropic_api_key` has been retired — the platform
# never spends the owner's Anthropic credits on a user's behalf.
# Polymarket operating mode. :paper simulates fills against live Gamma
# prices without any CLOB calls; :live would route to the Polymarket
# CLOB API (not yet wired — requires a funded wallet). Admin-only flip.
# Pre-computed so the case/-> clauses do not land inside the config
# keyword list (parse ambiguity in Elixir 1.17+).
polymarket_mode =
  if System.get_env("POLYMARKET_MODE") == "live", do: :live, else: :paper

# Kite Collective Intelligence salt — keys the HMAC used for
# source_org_hash / source_trade_hash so opt-out purges still match
# rows even if KiteAgentHubWeb.Endpoint :secret_key_base is rotated.
# In prod we require a dedicated secret; the dev/test fallback in
# CollectiveIntelligence.salt/0 is intentionally a constant so the
# privacy guarantee is never silently dependent on shared key state.
collective_intelligence_salt = System.get_env("COLLECTIVE_INTELLIGENCE_SALT")

if config_env() == :prod and collective_intelligence_salt in [nil, ""] do
  raise """
  COLLECTIVE_INTELLIGENCE_SALT is not set.

  KCI uses an HMAC-SHA256 keyed off this secret to anonymize trade and
  org references. Without a dedicated salt the privacy guarantee depends
  on Endpoint :secret_key_base — if that ever rotates, opt-out purges
  silently miss rows.

  Set it on Fly:
      fly secrets set COLLECTIVE_INTELLIGENCE_SALT=$(openssl rand -hex 64)
  """
end

config :kite_agent_hub,
  workos_api_key: System.get_env("WORKOS_API_KEY") || "",
  workos_client_id: System.get_env("WORKOS_CLIENT_ID") || "",
  workos_redirect_uri:
    System.get_env("WORKOS_REDIRECT_URI") ||
      "http://localhost:4000/auth/workos/callback",
  agent_private_key: System.get_env("AGENT_PRIVATE_KEY") || "",
  # PR #101: Kite chain treasury address. KiteAttestationWorker sends a
  # tiny PYUSD transfer here from the agent wallet on every settled
  # trade — produces the on-chain proof the hackathon judges look for.
  kite_treasury_address: System.get_env("KITE_TREASURY_ADDRESS") || "",
  kite_treasury_address_mainnet: System.get_env("KITE_TREASURY_ADDRESS_MAINNET") || "",
  polymarket_mode: polymarket_mode,
  collective_intelligence_salt: collective_intelligence_salt

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/kite_agent_hub start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :kite_agent_hub, KiteAgentHubWeb.Endpoint, server: true
end

config :kite_agent_hub, KiteAgentHubWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  # TCP keepalive prevents Fly's edge proxy from reaping idle Postgres
  # connections. Without this, idle pool members get silently closed
  # (`tcp recv (idle): closed`) and the next dispatch hits a reconnect
  # storm — observed 2026-05-07 on ObanRepo where 22 queue producers
  # contended with 10+ stale Postgrex connections on every tick.
  # `idle_interval` adds a belt-and-suspenders ping every 30s.
  pg_socket_options = [keepalive: true] ++ maybe_ipv6

  config :kite_agent_hub, KiteAgentHub.Repo,
    # ssl: true,
    url: database_url,
    # Bumped from 10 → 25 default. Each AgentRunner tick holds a
    # connection through the entire Repo.with_user block, which
    # currently includes slow LLM / HTTP-oracle calls. Pool exhaustion
    # was causing tick GenServer crashes under load. Long term: refactor
    # to release the connection before slow non-DB work.
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "25"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: pg_socket_options,
    idle_interval: 30_000

  # Dedicated Oban pool — see `KiteAgentHub.ObanRepo`. Sized to cover
  # 22 queue producer slots + Notifier LISTEN + Stager + headroom for
  # agent enqueue bursts. Same DATABASE_URL as the main Repo; only the
  # connection fan-in is isolated.
  config :kite_agent_hub, KiteAgentHub.ObanRepo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("OBAN_POOL_SIZE") || "25"),
    socket_options: pg_socket_options,
    idle_interval: 30_000

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :kite_agent_hub, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :kite_agent_hub, KiteAgentHubWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: ["//#{host}", "//*.#{host}", "//*.fly.dev"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :kite_agent_hub, KiteAgentHubWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :kite_agent_hub, KiteAgentHubWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # From-address for outbound email. Set MAILER_FROM_EMAIL to override.
  # Example: fly secrets set MAILER_FROM_EMAIL="Kite Agent Hub <support@yourdomain.com>"
  # Defaults to Resend's free sandbox sender (works without custom domain verification).
  if from_email = System.get_env("MAILER_FROM_EMAIL") do
    config :kite_agent_hub, mailer_from_email: from_email
  end

  # Invite-only signup. ON in prod by default; set INVITE_ONLY_SIGNUP=false
  # to disable and allow open registration (e.g. during a one-off load test).
  config :kite_agent_hub,
    invite_only_signup: System.get_env("INVITE_ONLY_SIGNUP", "true") == "true"

  # Where access-request notifications are sent (admin notifications, NOT
  # the from-address). Defaults to support@kiteagenthub.com.
  config :kite_agent_hub,
    admin_notification_email:
      System.get_env("ADMIN_NOTIFICATION_EMAIL", "support@kiteagenthub.com")

  # Comma-separated list of admin email addresses (case-insensitive).
  # Example: ADMIN_EMAILS="damicomartinz@gmail.com,dmartin@developmoore.com"
  config :kite_agent_hub,
    admin_emails: System.get_env("ADMIN_EMAILS", "")

  # Public base URL used when rendering links inside emails.
  config :kite_agent_hub,
    app_base_url: System.get_env("APP_BASE_URL", "https://kiteagenthub.com")

  # Default Kite chain id used wherever an agent row's chain_id is nil
  # or a freshly inserted row needs a value. Testnet (2368) stays the
  # default so prod doesn't accidentally flip to mainnet on a misconfig.
  # Operators flip platform-wide to mainnet by setting KITE_CHAIN_ID=2366.
  # Routing modules (KiteAttestationWorker, GaslessClient, TxSigner)
  # continue to carry explicit testnet/mainnet constants for dispatch.
  config :kite_agent_hub,
    kite_chain_id: System.get_env("KITE_CHAIN_ID", "2368") |> String.to_integer()

  # KAH ops-owned vault Passport address (passport-handoff §3).
  # Receives Rail B (per-trade x402 fee) payments. Loaded from
  # the KAH_VAULT_ADDRESS env (set via `fly secrets set ...`); the
  # literal is NEVER committed to repo per the CyberSec gate on PR-2.
  # Unset env → `KiteAgentHub.Kite.VaultConfig.address/0` returns nil
  # and Rail B flows treat fee accrual as disabled.
  config :kite_agent_hub,
    kah_vault_address: System.get_env("KAH_VAULT_ADDRESS")

  # Mailer — Resend adapter via Swoosh.
  # Swoosh 1.16 ships Swoosh.Adapters.Resend — no extra dependency.
  # Set RESEND_API_KEY via: fly secrets set RESEND_API_KEY=re_...
  if resend_key = System.get_env("RESEND_API_KEY") do
    config :kite_agent_hub, KiteAgentHub.Mailer,
      adapter: Swoosh.Adapters.Resend,
      api_key: resend_key

    config :swoosh, :api_client, Swoosh.ApiClient.Req
  end
end
