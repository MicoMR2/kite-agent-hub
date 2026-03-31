# Kite Agent Hub

**Encode Club × Kite AI Hackathon — March 27 – April 26, 2026**

A multi-tenant platform for deploying and managing autonomous AI trading agents on [Kite chain](https://gokite.ai). Agents are powered by Claude AI, score market edge with a custom EdgeScorer, execute trades via on-chain transactions, and report live P&L through a real-time dashboard.

**Live demo**: https://kite-agent-hub.fly.dev

---

## The Vision

Kite chain is the **trust and accountability layer for AI agents**. Agents can trade on any platform — Kite-native pairs, Alpaca equities, Kalshi prediction markets — and settle proof of every trade on-chain. The `TradingAgentVault` holds escrow, enforces per-trade and daily spend limits, and records P&L on Kite L1. No human needs to be in the loop; the chain is the auditor.

---

## What It Does

1. **Register & onboard** — Sign up with email or WorkOS SSO (Google, GitHub). An organization is auto-created on first login.
2. **Deploy an agent** — Give it a name, paste a funded Kite testnet wallet address, set per-trade and daily spend limits.
3. **Generate a wallet & verify vault** — Run `agent_onboard.py` to generate an EVM keypair saved to `~/.kite/agent_key.json` (chmod 600), then verify your `TradingAgentVault` is live on-chain before the agent activates.
4. **EdgeScorer signals** — The EdgeScorer tab scores ETH-USDC, BTC-USDC, and KITE-USDC 0–100 using trend (40 pts), RSI (30 pts), volume (20 pts), and 24h change (10 pts). Scores ≥ 75 → `:go`, 50–74 → `:hold`, < 50 → `:no`.
5. **Autonomous trading** — Every 60 seconds the agent fetches live price data, scores market edge, asks Claude Haiku for a buy/sell/hold signal with confidence score, and if signaled, submits a signed EIP-155 transaction to Kite chain.
6. **Real-time dashboard** — Three tabs: **Overview** (live P&L + agent controls), **Kite Wallet** (vault balance + Kitescan links + block number), **EdgeScorer** (market signal cards with score bars + breakdowns). All update live via Phoenix LiveView + PubSub.
7. **Trade history** — Filter by status (open / settled / failed / cancelled), paginate, see the AI's reasoning for each trade.
8. **JSON API** — External scripts can submit trade signals via `POST /api/v1/trades` (Alpaca/Kalshi bridge).

---

## Hackathon Demo Walkthrough

> For judges — this is the 5-minute path through the live app.

1. Visit **https://kite-agent-hub.fly.dev** → register a new account
2. Go to **Agents → New Agent** — name it, paste a funded testnet wallet address, set limits (e.g. $250 per-trade, $1,000 daily)
3. Check the **Dashboard → EdgeScorer tab** — see live 0–100 scores for ETH-USDC, BTC-USDC, KITE-USDC with GO/HOLD/NO badges
4. Hit **Activate** on your agent (Overview tab) — the 60-second loop starts
5. Check **Dashboard → Kite Wallet tab** — see your vault balance and live block number from Kite testnet
6. Visit **Trade History** — each trade shows market, action, fill price, P&L, and the AI's signal reasoning
7. Click any Kitescan link in the wallet tab → on-chain proof of every settlement

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Phoenix / LiveView                       │
│  /dashboard (Overview|Wallet|EdgeScorer) /trades /agents     │
│  /api/v1/trades  /api/v1/agents/me                          │
└────────────────────────┬────────────────────────────────────┘
                         │ PubSub broadcasts
┌────────────────────────▼────────────────────────────────────┐
│                  Kite Agent Loop                             │
│  AgentRunnerSupervisor → AgentRunner (GenServer per agent)   │
│    PriceOracle (CoinGecko) → EdgeScorer (0-100 signal score) │
│    → SignalEngine (Claude Haiku) → TradeExecutionWorker      │
│    → TxSigner (EIP-155) → RPC.send_raw_transaction          │
│    → Kite chain → SettlementWorker (polls tx receipt)        │
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
| `Kite.EdgeScorer` | 0–100 market edge score (Trend/RSI/Volume/Change) |
| `Kite.SignalEngine` | Claude Haiku → structured JSON trade signal |
| `Kite.AgentRunner` | GenServer tick loop per active agent |
| `Kite.AgentRunnerSupervisor` | DynamicSupervisor — starts/stops runners |
| `Kite.TxSigner` | EIP-155 transaction signing (ex_keccak + ex_secp256k1) |
| `Kite.VaultABI` | `TradingAgentVault` ABI calldata encoder |
| `Workers.TradeExecutionWorker` | Oban — validates limits, creates trade, submits tx |
| `Workers.SettlementWorker` | Oban — polls receipt, settles or marks failed |
| `Workers.PositionSyncWorker` | Oban — re-enqueues settlements for open trades |

---

## Kite Integrations

### TradingAgentVault (on-chain accountability)
Every agent is paired with a `TradingAgentVault` smart contract on Kite chain. The vault:
- Holds escrowed funds (non-custodial — private keys never stored server-side)
- Enforces per-trade and daily spend limits on-chain
- Records `openPosition` / `closePosition` calls as immutable proof of every trade
- Explorer: [testnet.kitescan.ai](https://testnet.kitescan.ai/)

### Gasless Transactions (`gasless.gokite.ai`)
Agent transactions use EIP-3009 off-chain signatures submitted to Kite's relayer (`https://gasless.gokite.ai/testnet`). Agents trade without needing to hold native KITE for gas — the relayer covers it.

### Account Abstraction SDK (`gokite-aa-sdk`)
Smart contract wallets via ERC-4337. `getAccountAddress()` generates deterministic wallet addresses from any signer. `sendUserOperationAndWait()` submits user operations through the bundler. Spending controls enforce per-agent budgets with time windows.

### Kite Agent Passport
OAuth-based agent identity layer. Agents register an ID and sign spending rules (a "Session"). The Kite MCP Tool handles `kite.pay()` calls — authorization, retries, and on-chain execution — without building identity infrastructure from scratch.

---

## Stack

- **Elixir / Phoenix 1.8.5** — LiveView 1.1, Bandit
- **Postgres** (Supabase) with Row Level Security enforced at DB layer
- **Oban 2.19** — persistent job queue for trade execution and settlement
- **WorkOS AuthKit** — SSO (Google, GitHub, etc.)
- **Anthropic API** — Claude Haiku for trade signal generation
- **Kite chain** — EVM-compatible (chain ID 2368 testnet / 2366 mainnet)
- **Fly.io** — deployment

---

## Local Setup

```bash
# Prerequisites: Elixir 1.17+, Postgres

mix deps.get
mix ecto.setup          # creates DB + runs migrations

# Required env vars:
export WORKOS_API_KEY=...
export WORKOS_CLIENT_ID=...
export WORKOS_REDIRECT_URI=http://localhost:4000/auth/workos/callback
export ANTHROPIC_API_KEY=...
export AGENT_PRIVATE_KEY=...   # 64-char hex, funded Kite testnet wallet

mix phx.server
# → http://localhost:4000
```

### Agent onboarding (Step 3)

```bash
pip install eth-account requests
python scripts/agent_onboard.py \
  --rpc-url https://rpc-testnet.gokite.ai/ \
  --chain-id 2368
```

This generates a fresh EVM keypair, saves it to `~/.kite/agent_key.json` (chmod 600, never printed to stdout), and verifies your vault contract is live on-chain. Copy the printed wallet address into the dashboard agent form.

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

The API is the bridge for off-chain bots (Alpaca, Kalshi) to report trades that settle accountability on Kite chain.

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
- **Mainnet RPC**: `https://rpc.gokite.ai/` (chain 2366)
- **Explorer**: `https://testnet.kitescan.ai/`
- **Gasless relayer**: `https://gasless.gokite.ai/testnet`
- **Vault contract**: `TradingAgentVault` — `openPosition`, `closePosition`, `vaultBalance`

---

Built for the [Encode Club × Kite AI Hackathon](https://www.encode.club/kite-ai-hackathon).
