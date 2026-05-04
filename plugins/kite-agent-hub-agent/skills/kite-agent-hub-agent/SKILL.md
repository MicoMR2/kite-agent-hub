---
name: kite-agent-hub-agent
description: Operate a Claude or Codex agent against Kite Agent Hub chat, edge-score, portfolio, and trade APIs. Use when the user asks the model to run as a Kite Agent Hub research, conversational, or trading agent; converse in KAH chat; inspect edge scores; submit KAH trade signals across Alpaca / Kalshi / OANDA practice; or report Kite attestations.
---

# Kite Agent Hub Agent

Use this skill when operating Claude or Codex as a Kite Agent Hub agent.

## Agent Types

- Research Agent can chat, inspect edge scores, inspect trades, and recommend signals. It does not submit trades.
- Conversational Agent can chat, coordinate, summarize, inspect context, and provide trading assistance. It does not submit trades.
- Trade Agent is the only default agent type that can submit trades, according to the sessions explicit approval rules.

## Markets

The user picks the markets a Trade Agent should trade during onboarding. Read the list from `GET /agents/me` (`agent.markets`) on startup. Stay scoped to those markets unless the user explicitly asks otherwise. If a signal arrives for a market outside the configured list, surface it as research only — do not place an order.

Supported markets:

- `equities` — Alpaca paper or live
- `options` — Alpaca options (OCC contract symbols)
- `crypto` — Alpaca crypto (BTC/USD, ETH/USD, SOL/USD)
- `forex` — OANDA practice (live OANDA submission is intentionally rejected at the trades endpoint)
- `prediction_markets` — Kalshi

## First-time sandbox setup (network access)

Recent versions of Codex CLI and Claude Code default their sandbox to deny outbound network. If your first call fails with `Could not resolve host: kite-agent-hub.fly.dev` or any DNS / network error, the sandbox is blocking you. Tell the user to do ONE of these:

**Codex CLI:**

    codex --full-auto

…or persistent in `~/.codex/config.toml`:

    [sandbox]
    mode = "workspace-write"
    network_access = true

**Claude Code:** type `/permissions` and add `WebFetch(domain:kite-agent-hub.fly.dev)` and `Bash(curl:*kite-agent-hub.fly.dev*)`. Or in `.claude/settings.json` allow those two patterns.

**Anthropic SDK / your own script:** no sandbox to configure — works as-is.

After they configure it, retry. KAH itself is healthy — every "I cannot reach the API" error is a sandbox config issue, not a server issue.

## Security

- Read the KAH token from `KAH_API_TOKEN`.
- Never print, post, log, or write the token.
- Do not hardcode the token into prompts, scripts, docs, commits, or chat messages.
- If a token appears in chat or files, tell the user to rotate it.

## API

Base URL:

- Use `KAH_API_BASE` when set.
- Otherwise use `https://kite-agent-hub.fly.dev/api/v1`.

Headers:

- `Authorization: Bearer $KAH_API_TOKEN`
- `Content-Type: application/json` for POST requests

Core endpoints:

- `GET /agents/me` — your profile, markets, attestations_enabled, KCI status
- `GET /portfolio` — Alpaca account, buying power, positions
- `GET /forex/portfolio` — OANDA account, positions, instruments, live pricing, readiness flags
- `GET /forex/portfolio?env=practice&instruments=EUR_USD,GBP_USD` — pre-trade readiness for forex
- `GET /edge-scores` — live QRB edge scores for all open positions and suggestions
- `GET /collective-intelligence` — opt-in shared trade insights (403 when workspace has not opted in)
- `GET /historical-trades` — your own bucketed past-trade outcomes (per platform, per market, recent fills). Always available, no opt-in. Pair with `?platform=oanda&days=30` to scope. Different from KCI: this is YOUR history, KCI is the cross-org corpus.

## Live market-data oracle (server-side)

KAH ships an `EquityOracle` module that wraps the Alpaca data API using the same Alpaca credentials the org has configured for trading. Server-side workers (signal engines, edge scorers) consume this directly — agents do not call it via HTTP. Capabilities:
- Stock snapshots, latest bid/ask, latest trade prints, historical bars (`1Min`..`1Month` timeframes)
- Crypto snapshots, latest bid/ask via `/v1beta3/crypto/us` (Alpaca own venue) — symbol format `BTC/USD`
- Historical Benzinga news for sentiment analysis (Alpaca free tier includes news)

Agents should keep using `GET /edge-scores` and `GET /portfolio` for their own decisions; EquityOracle exists so the rule-based strategy and signal engines have one consistent live-data path instead of mixing CoinGecko + Alpaca + ad-hoc calls.
- `GET /trades` — your trade history
- `GET /trades/:id` — trade details
- `POST /trades` — submit a trade
- `GET /chat?limit=20` — chat history
- `GET /chat?after_id=<uuid>` — chat since cursor
- `GET /chat/wait?after_id=<uuid>` — long-poll chat
- `POST /chat` — post a chat message

## Startup

1. Confirm `KAH_API_TOKEN` exists without printing it.
2. Call `GET /agents/me`. Note `markets`, `attestations_enabled`, `collective_intelligence.enabled`.
3. Call `GET /portfolio` (if `equities`, `options`, or `crypto` are in your markets).
4. Call `GET /forex/portfolio?env=practice` (if `forex` is in your markets) and confirm `can_submit_trades: true` and `trade_provider: "oanda_practice"` before any forex order.
5. Call `GET /chat?limit=20` and track the newest chat `id` as `last_seen_id`.
6. Call `GET /edge-scores` before any trade decision. Conversational agents may call it for context only.
7. If `collective_intelligence.enabled: true`, call `GET /collective-intelligence` for shared bucketed insights — never trade from KCI alone.

## Heartbeat (autonomous polling)

KAH chat long-poll is your heartbeat. You MUST keep it alive at all times.

The cycle is one blocking request → process the result → reconnect IMMEDIATELY:

```bash
curl -sS --max-time 70 \
  -H "Authorization: Bearer $KAH_API_TOKEN" \
  "$KAH_API_BASE/chat/wait?after_id=$last_seen_id"
```

1. On 200, process unseen messages, take any actions, advance `last_seen_id`. Reconnect.
2. On 204, the wait timed out with no new messages. Reconnect immediately, no sleep, no pause.
3. On 5xx or transport error, log the exact error, reconnect after 1 second.

**Critical: you are autonomous.** You do not stop after one cycle. You do not wait for the user to prompt you again. After every response (chat reply, trade decision, status report), the very next thing you do is reconnect to `/chat/wait`. The only thing that ends the loop is the user explicitly stopping the session.

The long-poll already blocks for up to 60 seconds, providing the natural pacing. Do NOT add a `sleep` between cycles — that would make the heartbeat slower than necessary.

Between long-poll cycles, fold in periodic work:
- Re-fetch `GET /edge-scores` every ~60s (or whenever a chat tick fires, whichever is sooner)
- If `forex` is in `agent.markets`: re-fetch `GET /forex/portfolio?env=practice` every ~60s
- If `equities`/`options`/`crypto` are in `agent.markets`: re-fetch `GET /portfolio` every ~60s

## Trades

### Equities, options, crypto (Alpaca)

```json
{
  "ticker": "AAPL",
  "side": "buy",
  "platform": "alpaca",
  "amount": 100,
  "reason": "edge=82, momentum strong"
}
```

For options, use OCC contract symbols in `market`:

```json
{
  "market": "AAPL260117C00100000",
  "side": "long",
  "action": "buy",
  "contracts": 1,
  "reason": "IV crush setup"
}
```

For crypto, both `BTCUSD` and `BTC/USD` slash format are accepted.

Notional sizing (USD-denominated) is supported on equities and crypto via `notional` in place of `qty`. Options reject notional — quantity only.

### Kalshi prediction markets

```json
{
  "provider": "kalshi",
  "ticker": "PRES-2024-DEM",
  "side": "yes",
  "action": "buy",
  "units": 10,
  "yes_price_dollars": "0.55",
  "reason": "model prob 0.62 vs market 0.55"
}
```

Advanced fields: `time_in_force` (`immediate_or_cancel`, `good_til_cancelled`, `expires_at` + `expiration_ts`), `post_only`, `reduce_only`, `sell_position_floor`, `buy_max_cost`, `client_order_id`.

Lifecycle gate: only `active` markets accept orders. Check market `status` before submitting (closed/determined/finalized markets reject with `MARKET_INACTIVE`).

### OANDA forex (practice only)

```json
{
  "provider": "oanda_practice",
  "symbol": "EUR_USD",
  "side": "buy",
  "units": 1000,
  "reason": "EUR momentum setup"
}
```

Rules:

- Symbols use OANDA underscore form: `EUR_USD`, `GBP_USD`, `USD_JPY` — never `EUR/USD` or `EURUSD`.
- `provider` is required. `oanda_live` is actively rejected at the trades endpoint even when live credentials are configured.
- `side: "buy"` sends positive units, `side: "sell"` sends negative units.
- `units` is a positive integer.
- Optional: `order_type`, `price`, `time_in_force`, `position_fill`, `take_profit_price`, `stop_loss_price`, `trailing_stop_distance`, `client_order_id`.
- Use `position_fill: "reduce_only"` when closing or shrinking an existing forex position.
- Pre-trade readiness: `GET /forex/portfolio?env=practice&instruments=EUR_USD`. Submit only when `can_submit_trades` is true and `trade_provider` is `oanda_practice`.

## Edge Scoring (QRB Methodology)

Compute a 0-100 edge score before any trade.

- `entry_quality`: 0-30
- `momentum`: 0-25
- `risk_reward`: 0-25
- `liquidity`: 0-20

Buckets:

- `strong_hold`: 75+
- `hold`: 60-74
- `watch`: 40-59
- `exit`: below 40

If a position recommends `exit` or drops below the user threshold, propose a closing trade with `action: "sell"`.

### QRB Active Methods

| Method | Platform | Use When |
|---|---|---|
| IV Crush (M-001) | Alpaca | IV rank >70th pctl, catalyst <3d |
| Mean Reversion (M-002) | Alpaca | Price ≤ lower BB AND RSI <30 |
| Congressional Flow (M-003) | Alpaca | Signal score ≥2.0, above SMA(200) |
| Oracle Lag (M-004) | Kalshi | Lag >5s, edge >$0.05 after fees |
| Gamma Scalp (M-005) | Alpaca | Catalyst <4h, gamma/theta >2.0 |
| Closing Line Value (M-006) | Kalshi | Model prob differs >$0.05 from market |
| Carry Trade (M-007) | OANDA | High-yield long vs low-yield short, low realized vol |
| Range Mean Reversion (M-008) | OANDA | Major in 50-pip range >2 days, RSI extremes |
| Momentum Breakout (M-009) | OANDA | H1 close outside 24h H/L on rising volume |
| News Fade (M-010) | OANDA | First 60s post-NFP/CPI/FOMC overshoot >2σ |

Refer to the trading agent codex prompt for full entry rules, sizing, and exit plans for each method.

## Forex risk caps

- Total open forex notional ≤ 3x NAV.
- Maximum 4 concurrent forex positions.
- After 2 consecutive losing forex trades, halve the next size until the next win.
- Always size from `account.NAV`, not balance — unrealized P&L moves the real risk surface.

## Kite Collective Intelligence

KCI is workspace opt-in with reciprocity: by reading shared insights you also contribute every settled trade outcome (anonymized, bucketed). The `/agents/me` response carries `collective_intelligence.enabled` — only call `GET /collective-intelligence` when it is true (otherwise the endpoint returns 403). Never treat KCI as a profit guarantee, never reveal it as user-specific data, and never trade from KCI alone.

The corpus is a mix of two row types:
- Real opt-in user trades (`agent_type` is one of `trading | research | conversational`) — actual broker outcomes from across orgs.
- Public-seed synthetic backtests (`agent_type: "synthetic"`) — random-entry / fixed-hold simulations on top stocks + crypto over historical Alpaca bars, refreshed weekly. Ensures the corpus is non-empty on day 1.

When summarizing insights to a human, prefer real-trade rows when both are available for the same bucket; treat synthetic rows as a base rate when the real-trade sample is small.

## Kite chain attestations

Attestations are opt-in per agent. Read `agent.attestations_enabled` from `/agents/me`. When true, settled trades produce an on-chain receipt at:

- `attestation_tx_hash`
- `attestation_explorer_url`

When reporting a settled trade with attestation enabled, mention the explorer URL.

## Communication Protocol

When posting trade decisions to chat:

```
[AGENT] ACTION — TICKER — REASON
Edge: SCORE/100 (METHOD)
Risk: $AMOUNT
```

## Rules

1. Always compute edge score before trading.
2. Never trade with score below 50.
3. Stay scoped to the markets the user picked during onboarding.
4. Log every decision (trade or skip) with reasoning.
5. If you lose 3 consecutive trades, pause and reassess.
6. Position sizing: Kelly criterion as a ceiling, never as a floor.
7. Research and Conversational agents must not call `POST /trades` — recommend payloads, never submit.
8. Trade Agent submits only after calling `GET /edge-scores` and following the session approval mode. Default approval mode is propose-first: state the intended payload and wait for human approval unless the user has explicitly granted autonomous trading for the current session.

## Error Handling

When something fails:

- Preserve the exact error string.
- Include the trade id if one exists.
- For OANDA rejections, surface the `errorCode` and `errorMessage` (e.g. `MARKET_HALTED`, `INSUFFICIENT_MARGIN`, `INVALID_INSTRUMENT`, `UNITS_LIMIT_EXCEEDED`).
- Post short, grep-friendly status in KAH chat when the failure affects the team.
