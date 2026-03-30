# Kite Agent Hub

**Encode Club × Kite AI Hackathon — March 27 – April 26, 2026**

A multi-tenant platform for deploying and managing autonomous AI trading agents on [Kite chain](https://gokite.ai). Agents are powered by Claude AI, execute trades via on-chain transactions, and report live P&L through a real-time dashboard.

---

## What It Does

1. **Register & onboard** — Sign up with email or WorkOS SSO (Google, GitHub, etc). An organization is auto-created on first login.
2. **Deploy an agent** — Give it a name, paste a funded Kite testnet wallet address, set per-trade and daily spend limits.
3. **Activate a vault** — Point the agent at a `TradingAgentVault` contract address. The agent goes live immediately.
4. **Autonomous trading** — Every 60 seconds the agent fetches live ETH/USD price from CoinGecko, asks Claude Haiku for a buy/sell/hold signal with confidence score, and if signaled, submits a signed EIP-155 transaction to Kite chain.
5. **Real-time dashboard** — Watch P&L, open positions, wallet balance, and block number update live via Phoenix LiveView + PubSub. Pause/resume any agent with one click.
6. **Trade history** — Filter by status, paginate, see the AI's reasoning for each trade.
7. **JSON API** — External scripts can submit trade signals via `POST /api/v1/trades`.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Phoenix / LiveView                       │
│  /dashboard  /trades  /agents/new  /api/v1/trades           │
└────────────────────────┬────────────────────────────────────┘
                         │ PubSub broadcasts
┌────────────────────────▼────────────────────────────────────┐
│                  Kite Agent Loop                             │
│  AgentRunnerSupervisor → AgentRunner (GenServer per agent)   │
│    PriceOracle (CoinGecko) → SignalEngine (Claude Haiku)     │
│    → TradeExecutionWorker (Oban) → TxSigner (EIP-155)        │
│    → RPC.send_raw_transaction → Kite chain                   │
│    → SettlementWorker (Oban, polls eth_getTransactionReceipt)│
└────────────────────────┬────────────────────────────────────┘
                         │ Ecto + Postgres RLS
┌────────────────────────▼────────────────────────────────────┐
│  organizations → org_memberships → users                     │
│  kite_agents → trade_records                                 │
│  RLS: every table filtered by current_user_org_ids()         │
└─────────────────────────────────────────────────────────────┘
```

### Key modules

| Module | Purpose |
|--------|---------|
| `Kite.RPC` | JSON-RPC client — all `eth_*` calls to Kite chain |
| `Kite.PriceOracle` | CoinGecko live price + 24h trend + approx RSI |
| `Kite.SignalEngine` | Claude Haiku → structured JSON trade signal |
| `Kite.AgentRunner` | GenServer tick loop per active agent |
| `Kite.AgentRunnerSupervisor` | DynamicSupervisor — starts/stops runners |
| `Kite.TxSigner` | EIP-155 transaction signing (ex_keccak + ex_secp256k1) |
| `Kite.VaultABI` | `TradingAgentVault` ABI calldata encoder |
| `Workers.TradeExecutionWorker` | Oban — validates limits, creates trade, submits tx |
| `Workers.SettlementWorker` | Oban — polls receipt, settles or marks failed |
| `Workers.PositionSyncWorker` | Oban — re-enqueues settlements for open trades |

---

## Stack

- **Elixir / Phoenix 1.8.5** — LiveView 1.1, Bandit
- **Postgres** (Supabase) with Row Level Security enforced at DB layer
- **Oban 2.19** — persistent job queue for trade execution and settlement
- **WorkOS AuthKit** — SSO (Google, GitHub, etc.)
- **Anthropic API** — Claude Haiku for trade signal generation
- **Kite chain** — EVM-compatible (chain ID 2368 testnet / 2366 mainnet)
- **Fly.io** — deployment target

---

## Local Setup

```bash
# Prerequisites: Elixir 1.17+, Postgres

mix deps.get
mix ecto.setup          # creates DB + runs migrations

# Required env vars (copy to .env or export):
export WORKOS_API_KEY=...
export WORKOS_CLIENT_ID=...
export WORKOS_REDIRECT_URI=http://localhost:4000/auth/workos/callback
export ANTHROPIC_API_KEY=...
export AGENT_PRIVATE_KEY=...   # 64-char hex, funded Kite testnet wallet

mix phx.server
# → http://localhost:4000
```

---

## API

All endpoints require `Authorization: Bearer <agent_wallet_address>`.

```
POST /api/v1/trades
  Body: { market, side, action, contracts, fill_price, reason? }
  Returns: { ok, job_id, status: "queued" }

GET  /api/v1/trades?status=open&limit=50
GET  /api/v1/trades/:id
GET  /api/v1/agents/me
```

---

## Production Deploy (Fly.io)

```bash
fly secrets set \
  DATABASE_URL=... \
  SECRET_KEY_BASE=$(mix phx.gen.secret) \
  WORKOS_API_KEY=... \
  WORKOS_CLIENT_ID=... \
  WORKOS_REDIRECT_URI=https://kite-agent-hub.fly.dev/auth/workos/callback \
  ANTHROPIC_API_KEY=... \
  AGENT_PRIVATE_KEY=...

fly deploy
# Migrations run automatically via release_command in fly.toml
```

---

## Kite Chain

- **Testnet RPC**: `https://rpc-testnet.gokite.ai/` (chain 2368)
- **Explorer**: `https://testnet.kitescan.ai/`
- **Vault contract**: `TradingAgentVault` — `openPosition`, `closePosition`, `vaultBalance`

---

Built for the [Encode Club × Kite AI Hackathon](https://www.encode.club/kite-ai-hackathon).
