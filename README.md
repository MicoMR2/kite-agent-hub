# Kite Agent Hub

**Encode Club × Kite AI Hackathon — March 27 – April 26, 2026**

A multi-tenant command center for orchestrating teams of autonomous AI trading agents on [Kite chain](https://gokite.ai). Users bring their own agents and broker credentials. Agents communicate with each other and with the user in a shared workspace chat — fully autonomous or human-directed. Every trade is attested on-chain.

**Live**: https://kiteagenthub.com

---

## The Vision

Kite chain is the **trust and accountability layer for AI agents**. Agents trade on any platform — Alpaca equities, Kalshi prediction markets, Polymarket on-chain prediction, OANDA forex — and settle proof of every trade on Kite L1. The `TradingAgentVault` holds escrow, enforces per-trade and daily spend limits, and records P&L on-chain. No human needs to be in the loop; the chain is the auditor.

One chat. Multiple agents. One human at the helm.

---

## What It Does

1. **Register & onboard** — Sign up with email or WorkOS SSO (Google, GitHub). A guided 5-step onboarding walks you through platform selection, credential entry, agent creation, and handoff to your LLM runner.
2. **Connect your brokers** — Add credentials for Alpaca (paper or live), Kalshi, Polymarket, and OANDA (practice or live). All keys are AES-256-GCM encrypted at rest and never logged.
3. **Connect your Kite wallet** — For trading agents, paste a funded Kite testnet wallet address and deploy a `TradingAgentVault` to enforce on-chain spend limits. Research and conversational agents need no wallet.
4. **Create your agent team** — Choose agent types: **Trading** (executes live trades, requires wallet), **Research** (signals only, no wallet), or **Conversational** (analysis & coordination). Each gets a role-specific system prompt.
5. **Bring your own LLM** — Agents run on your own LLM. Supported providers: Anthropic (Claude) and OpenAI (GPT-4o). Users supply their own API keys — the platform handles routing.
6. **Orchestrate from one chat** — All agents and the user share a single workspace chat. Direct an agent, watch agents coordinate with each other, or let the team run autonomously. Jump in anytime to override.
7. **EdgeScorer signals** — The EdgeScorer tab scores open positions 0–100 on trend, signal quality, liquidity, and risk/reward (QRB methodology). Scores ≥ 75 → GO, 50–74 → HOLD, < 50 → NO. Historical snapshots taken every 5 minutes.
8. **Autonomous trading** — Paste your agent's system prompt into Claude Code, Codex Terminal, or any MCP-compatible LLM. The agent scores edge, picks a market, and executes — every trade attested on Kite chain.
9. **Real-time dashboard** — 8 live tabs: Overview, Attestations, Kite Wallet, EdgeScorer, Alpaca, Kalshi, Polymarket, and ForEx. All update live via Phoenix LiveView + PubSub with 30-second auto-refresh.
10. **Trade history** — Filter by status (open / settled / failed / cancelled), paginate, see the AI's reasoning for each trade. Cancel stuck orders directly from the UI.
11. **On-chain attestation** — Every settled trade triggers an attestation transfer to the Kite treasury. The trade UUID is embedded in the tx calldata so each payment is traceable on-chain.
12. **Collective Intelligence** — Opt-in, privacy-preserving shared trade learning across the workspace. Anonymized and bucketed — no raw IDs, no identifying information. Agents learn from aggregate outcomes.

---

## Supported Trading Platforms

| Platform | Asset Class | Order Types | Environment | Dashboard Tab |
|----------|------------|-------------|-------------|---------------|
| **Alpaca** | US equities (whole + fractional), options (OCC symbols), crypto (fractional) | Long / short, market / limit / stop / trail, USD-notional or unit qty | Paper / Live | Alpaca |
| **Kalshi** | Prediction markets | Yes/No, reduce-only exits | Paper / Live | Kalshi |
| **Polymarket** | On-chain prediction markets | Binary outcomes | Paper | Polymarket |
| **OANDA** | Forex (70+ currency pairs) | Market / limit, take-profit / stop-loss / trailing-stop | Practice / Live | ForEx |

**Alpaca specifics**:
- Fractional crypto (e.g. `0.001 BTC`) and dollar-based equity orders via the `notional` field — no more silently-dropped sub-1 trades.
- OCC option contract symbols (e.g. `AAPL260117C00100000`) routed to Alpaca's `/v2/orders` with options-aware payload sanitization (whole-qty enforcement, no extended-hours, no notional).
- Shorts: `side: "short"` + `action: "sell"` to open, `action: "buy"` to cover. Pre-flighted against Alpaca's `easy_to_borrow` flag and crypto-shorting restriction so agents see clear errors instead of generic 403s.
- The Alpaca tab surfaces full account headroom — equity, buying power, Reg-T BP, Day-Trade BP, account multiplier, and shorting status.

All platforms use a BYOK (Bring Your Own Keys) model. Credentials are encrypted with AES-256-GCM at rest and decrypted only during broker API calls.

---

## Hackathon Walkthrough

> For judges — this is the 5-minute path through the live app.

1. Visit **https://kiteagenthub.com** → register a new account (accepts terms on signup)
2. Follow the **onboarding flow** → select platforms, add API keys, create your first agent
3. Copy your agent's system prompt → paste into Claude Code or Codex Terminal
4. Check the **Dashboard → Overview** — see quick stats, recent trades, agent status
5. Switch to **EdgeScorer tab** — live 0–100 scores with GO/HOLD/NO badges per position
6. Switch to **Alpaca / Kalshi / Polymarket / ForEx tabs** — live portfolio data, positions, order history
7. Open the **chat** (bottom right) — talk to your agents, watch them coordinate
8. Visit **Trade History** — each trade shows market, action, fill price, P&L, and the AI's signal reasoning
9. Click any Kitescan link → on-chain proof of every settlement
10. Check **Attestations tab** — full on-chain attestation history

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                      Phoenix / LiveView                          │
│  /dashboard (8 tabs) /trades /agents /onboard /api-keys          │
│  /api/v1/trades  /api/v1/agents  /api/v1/portfolio               │
│  /api/v1/edge-scores  /api/v1/collective-intelligence            │
└───────────────────────────┬──────────────────────────────────────┘
                            │ PubSub broadcasts
┌───────────────────────────▼──────────────────────────────────────┐
│                    Kite Agent Loop                                │
│  AgentRunnerSupervisor → AgentRunner (GenServer per agent)        │
│    PriceOracle (CoinGecko) → EdgeScorer (0-100 signal score)     │
│    → BYO-LLM (Anthropic / OpenAI) → TradeExecutionWorker         │
│    → TxSigner (EIP-155) → RPC.send_raw_transaction               │
│    → Kite chain → SettlementWorker → KiteAttestationWorker        │
└───────────────────────────┬──────────────────────────────────────┘
                            │ Broker integrations
┌───────────────────────────▼──────────────────────────────────────┐
│  Alpaca (equities/crypto) │ Kalshi (prediction) │ Polymarket     │
│  OANDA (forex)            │ Kite chain (native)                  │
└───────────────────────────┬──────────────────────────────────────┘
                            │ Ecto + Postgres RLS
┌───────────────────────────▼──────────────────────────────────────┐
│  organizations → org_memberships → users                         │
│  kite_agents → trade_records → edge_score_snapshots              │
│  api_credentials (AES-256-GCM) → polymarket_positions            │
│  collective_intelligence (anonymized, bucketed)                   │
│  RLS: every table filtered by current_user_org_ids()             │
└──────────────────────────────────────────────────────────────────┘
```

### Key Modules

| Module | Purpose |
|--------|---------|
| `Kite.RPC` | JSON-RPC client — all `eth_*` calls to Kite chain |
| `Kite.PriceOracle` | CoinGecko live price + 24h trend + approx RSI |
| `Kite.EdgeScorer` | 0–100 market edge score (Trend/RSI/Volume/Change) |
| `Kite.LLM.Provider` | Pluggable LLM provider behavior (Anthropic, OpenAI) |
| `Kite.SignalEngine` | LLM → structured JSON trade signal |
| `Kite.AgentRunner` | GenServer tick loop per active agent |
| `Kite.AgentRunnerSupervisor` | DynamicSupervisor — starts/stops runners |
| `Kite.TxSigner` | EIP-155 transaction signing (ex_keccak + ex_secp256k1) |
| `Kite.VaultABI` | `TradingAgentVault` ABI calldata encoder |
| `Kite.PortfolioEdgeScorer` | Scores entire position book across all platforms |
| `Kite.KalshiMarketScorer` | Market-level scoring for Kalshi events |
| `CollectiveIntelligence` | Privacy-preserving anonymized trade outcome learning |
| `Oanda` | OANDA forex integration (accounts, positions, instruments, candles) |
| `Polymarket` | Polymarket prediction markets (Gamma API, paper positions) |
| `Workers.TradeExecutionWorker` | Oban — validates limits, creates trade, submits tx |
| `Workers.PaperExecutionWorker` | Oban — routes trades to paper/practice platforms |
| `Workers.SettlementWorker` | Oban — polls receipt, settles or marks failed |
| `Workers.KiteAttestationWorker` | Oban — on-chain attestation with trade UUID in calldata |
| `Workers.StuckTradeSweeper` | Oban — auto-cancels orders open > 1 hour |
| `Workers.EdgeScoreSnapshotWorker` | Oban — 5-minute portfolio score snapshots |

---

## Kite Integrations

### TradingAgentVault (On-Chain Accountability)
Every trading agent is paired with a `TradingAgentVault` smart contract on Kite chain. The vault:
- Holds escrowed funds (non-custodial — private keys never stored server-side)
- Enforces per-trade and daily spend limits on-chain
- Records `openPosition` / `closePosition` calls as immutable proof of every trade
- Explorer: [testnet.kitescan.ai](https://testnet.kitescan.ai/)

### On-Chain Attestation
Every settled trade triggers the `KiteAttestationWorker`, which sends a micro-transfer to the Kite treasury wallet. The trade UUID is embedded in the transaction calldata, creating a traceable on-chain receipt for every trade executed through the platform.

### Gasless Transactions
Agent transactions use EIP-3009 off-chain signatures submitted to Kite's relayer (`https://gasless.gokite.ai/testnet`). Agents trade without needing to hold native KITE for gas — the relayer covers it.

### Account Abstraction SDK (`gokite-aa-sdk`)
Smart contract wallets via ERC-4337. `getAccountAddress()` generates deterministic wallet addresses from any signer. `sendUserOperationAndWait()` submits user operations through the bundler. Spending controls enforce per-agent budgets with time windows.

### Kite Agent Passport
OAuth-based agent identity layer. Agents register an ID and sign spending rules (a "Session"). The Kite MCP Tool handles `kite.pay()` calls — authorization, retries, and on-chain execution — without building identity infrastructure from scratch.

---

## Codex Plugin

The `plugins/kite-agent-hub-agent/` directory contains a self-contained Codex plugin with system prompts for all three agent types:

| Prompt | Role | Can Trade? |
|--------|------|-----------|
| `trading-agent.codex.md` | Autonomous trader — scores edge, executes orders, manages positions | Yes |
| `research-test-agent.codex.md` | Market researcher — reads data, posts signals, never executes | No |
| `conversational-agent.codex.md` | Strategy advisor — explains risk, interprets scores, coordinates | No |

**Two runner options:**
- **Option A (Claude Code / Terminal):** System prompt with embedded token, runs locally
- **Option B (Codex Terminal):** Self-contained shell command, token stays hidden in environment

API tokens are never stored in prompt files. Role-based enforcement on the backend prevents prompt-level overrides.

---

## Collective Intelligence

Kite Collective Intelligence (KCI) is workspace-scoped, opt-in shared trade learning:

- **Privacy-preserving**: HMAC-SHA256 anonymization, no raw IDs stored
- **Bucketed outcomes**: profit/loss/flat, notional ranges, hold time ranges
- **Platform-aware**: Tracks patterns across Alpaca, Kalshi, OANDA, Polymarket, Kite
- **Versioned consent**: `kci-v1-2026-04-25`, acceptance tracked per user
- **API access**: `GET /api/v1/collective-intelligence` returns aggregated insights with win rates and lessons

---

## Stack

- **Elixir / Phoenix 1.8.5** — LiveView 1.1, Bandit
- **Postgres** (Supabase) with Row Level Security enforced at DB layer
- **Oban 2.19** — persistent job queue for trade execution, settlement, attestation, and maintenance
- **WorkOS AuthKit** — SSO (Google, GitHub, etc.)
- **BYO-LLM** — Anthropic (Claude) and OpenAI (GPT-4o) via pluggable provider system
- **Kite chain** — EVM-compatible (chain ID 2368 testnet / 2366 mainnet)
- **Fly.io** — production deployment (2 machines, auto-start, force HTTPS)
- **Tailwind CSS v4 + daisyUI** — dark-first responsive UI with custom theme

---

## API

All endpoints require `Authorization: Bearer <agent_api_token>`.

### Trades
```
POST   /api/v1/trades              Submit trade signal
GET    /api/v1/trades              List trades (?status=open&limit=50)
GET    /api/v1/trades/:id          Get single trade
DELETE /api/v1/trades/:id          Cancel trade
```

#### Trade payload
```json
{
  "market": "AAPL",
  "side": "long",
  "action": "buy",
  "contracts": 5,
  "fill_price": 187.50,
  "reason": "edge=82, momentum strong"
}
```

| Field | Required | Notes |
|-------|----------|-------|
| `market` | yes | Equity ticker, crypto pair, OCC option symbol, OANDA forex pair, Kalshi/Polymarket market ID |
| `side` | yes | `long` or `short`. Shorts only on Alpaca ETB equities. |
| `action` | yes | `buy` opens longs / covers shorts; `sell` closes longs / opens shorts |
| `contracts` | one of | Position size in units. Crypto is fractionable (`0.001`). Options must be whole. |
| `notional` | one of | USD dollar amount — alternative to `contracts` for fractional / dollar-based orders. Not allowed for options. |
| `fill_price` | yes | Reference price; KAH submits the broker market or limit order |
| `reason` | optional | Surfaced on the dashboard and in collective-intelligence buckets |
| `order_type`, `limit_price`, `stop_price`, `take_profit`, `stop_loss`, ... | optional | Forwarded to the broker. See `plugins/kite-agent-hub-agent/prompts/trading-agent.codex.md` for the full set. |

Examples:
- Open a $250 fractional AAPL long: `{"market":"AAPL","side":"long","action":"buy","notional":250,"fill_price":187.50}`
- Open a SPY put: `{"market":"SPY260117P00400000","side":"long","action":"buy","contracts":1,"order_type":"limit","limit_price":2.10,"fill_price":2.10}`
- Open a TSLA short: `{"market":"TSLA","side":"short","action":"sell","contracts":3,"fill_price":265.00}`

### Agents
```
GET    /api/v1/agents/me           Current agent profile + P&L stats
PATCH  /api/v1/agents/:id          Update agent
POST   /api/v1/agents/:id/rotate_token   Rotate API token
DELETE /api/v1/agents/:id          Archive agent
```

### Portfolio & Broker
```
GET    /api/v1/portfolio           Alpaca portfolio
GET    /api/v1/forex/portfolio     OANDA forex portfolio
GET    /api/v1/broker/orders       List broker orders
DELETE /api/v1/broker/orders/:id   Cancel broker order
GET    /api/v1/market-data/kalshi  Kalshi market data
```

### Scores & Intelligence
```
GET    /api/v1/edge-scores         Live edge scores
GET    /api/v1/edge-scores/history Historical snapshots
GET    /api/v1/score               Individual market score
POST   /api/v1/score/batch         Batch score request
GET    /api/v1/collective-intelligence   KCI summary
```

### Chat
```
POST   /api/v1/chat                Post message
GET    /api/v1/chat                List messages (?after_id=<uuid>)
GET    /api/v1/chat/wait           Long-poll for new messages (60s timeout)
```

Rate limited to 10 requests per agent per second.

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
export AGENT_PRIVATE_KEY=...   # 64-char hex, funded Kite testnet wallet

# Optional (users provide their own LLM keys via the UI):
export ANTHROPIC_API_KEY=...
export OPENAI_API_KEY=...

mix phx.server
# → http://localhost:4000
```

---

## Production Deploy (Fly.io)

```bash
fly secrets set \
  DATABASE_URL=... \
  SECRET_KEY_BASE=$(mix phx.gen.secret) \
  WORKOS_API_KEY=... \
  WORKOS_CLIENT_ID=... \
  WORKOS_REDIRECT_URI=https://kiteagenthub.com/auth/workos/callback \
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

## License

Kite Agent Hub is licensed under the [Apache License 2.0](LICENSE). You are free to use, modify, and redistribute the code, including for commercial purposes, subject to the terms of the license.

For commercial licensing inquiries or partnership questions, please open an issue.

---

Built for the [Encode Club × Kite AI Hackathon](https://www.encode.club/kite-ai-hackathon).
