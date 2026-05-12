# Passport Client Runbook

> Status: hackathon-ready (Passport PR-7, 2026-05-11). Reflects KAH v487
> and the trigger dispatch endpoint shipped in PR #361.

This runbook describes how a user runs the **client-side trade executor** for
a Kite Agent Hub (KAH) agent that has opted into the Passport **per-trade fee
rail**. KAH itself never executes the trade and never holds the user's
brokerage credentials or Passport authority — see the [Non-custodial
invariant](#non-custodial-invariant) immediately below the architecture
diagram.

## Audience

A user (or their Claude Code instance) who:

- Has registered a trading agent on KAH (`/users/settings/agents`)
- Has connected a personal Kite Passport to that agent via the "Connect
  Passport" panel (PR-5)
- Has selected payment rail `per_trade` (PR-5)
- Holds their own brokerage credentials (Alpaca, Kalshi, OANDA) locally —
  KAH never sees them

## Architecture

```
┌────────────────────┐    1. trade intent       ┌────────────────────────┐
│  KAH AgentRunner   │ ───────────────────────▶ │  trigger_events table  │
│  (server-side)     │                          │  (pending)             │
└────────────────────┘                          └─────────┬──────────────┘
                                                          │
                                                          │ 2. long-poll
                                                          ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Client runner  (this runbook — runs on YOUR machine)                │
│                                                                      │
│   GET /api/v1/triggers/pending  ──▶  for each event:                 │
│      • Execute on broker (Alpaca/Kalshi/OANDA) with LOCAL creds      │
│      • If Rail B: pay x402 fee → vault, capture receipt              │
│      • POST /api/v1/trades  with X-Payment-Receipt header            │
│      • POST /api/v1/triggers/:id/ack                                 │
└──────────────────────────────────────────────────────────────────────┘
```

KAH owns the **intent layer** (when/what to trade) and the **fee accrual ledger**
(`fee_accruals` rows). The user's machine owns the **execution layer** (the
actual broker order) and any credentials needed to authorize it.

## Non-custodial invariant

**KAH never receives, stores, or processes any of the following** (CyberSec
ask 6, msg 9140):

- Brokerage api_key
- Brokerage api_secret
- kpass private key
- Passport JWT / session token
- User wallet private key

Each of these stays on the user's machine, in the user's secret store. The
only Passport-related value KAH ever holds is the **public**
`passport_wallet_address` the user pasted into the linking form (PR-5). The
only payment-related value KAH ever holds is the **opaque x402 receipt
string** (PR-4) — a public payment proof against the vault address, not an
authorization token.

If a future change to this runbook ever instructs you to send any item from
the bullet list above to a KAH endpoint, treat the document as compromised
and stop.

## Auth

The client runner authenticates to KAH with the **agent api_token** issued
when the agent was created (rotatable from the agent settings page). That
token grants only the operations defined on the agent — trade submission,
trigger polling, and ack — scoped to that one agent.

```
Authorization: Bearer <YOUR_AGENT_API_TOKEN>
```

`<YOUR_AGENT_API_TOKEN>` is a placeholder. Do not paste a real token into any
example, screenshot, or shared document.

Passport authentication on the client side (signing the x402 receipt) is
handled by the kpass client itself — its session model is documented at
`https://agentpassport.ai`. Do not attempt to forward kpass session material
to KAH.

## Poll loop

The reference poll loop is below in shell pseudocode. A production runner
(kpass extension, Claude Code skill, or a small daemon) implements the same
shape with real broker SDKs.

```bash
KAH=https://kiteagenthub.com
# Set the agent token via your platform's secret manager — never
# commit it to a repo and never paste it into a shared document.
# Refer to your secret-manager docs for the appropriate command.
# (Example only: this runbook does not endorse storing secrets in shell env.)
TOKEN="<YOUR_AGENT_API_TOKEN>"

while true; do
  # 1. Long-poll triggers (returns after up to 10s if nothing pending).
  events=$(curl -fsSL -H "Authorization: Bearer $TOKEN" \
    "$KAH/api/v1/triggers/pending")

  # 2. For each event in events.events:
  #    a. Look up symbol/side/qty in the whitelisted fields.
  #    b. Execute on your broker using LOCAL credentials.
  #    c. If Rail B, pay the x402 fee via your kpass client and capture
  #       the receipt as $RECEIPT. The receipt is an opaque base64
  #       string (CyberSec ask 5, msg 9140) — never parse or modify
  #       it; pass it through to KAH as-is.
  #    d. POST the trade back to KAH for attestation:
  #
  #       curl -fsSL -X POST \
  #         -H "Authorization: Bearer $TOKEN" \
  #         -H "X-Payment-Receipt: $RECEIPT" \
  #         -H "Content-Type: application/json" \
  #         -d "$TRADE_BODY" \
  #         "$KAH/api/v1/trades"
  #
  #    e. Ack the trigger so the dashboard reflects delivery:
  #
  #       curl -fsSL -X POST \
  #         -H "Authorization: Bearer $TOKEN" \
  #         "$KAH/api/v1/triggers/$EVENT_ID/ack"
done
```

### Response shape from `GET /api/v1/triggers/pending`

```json
{
  "ok": true,
  "events": [
    {
      "id": "5f8c…",
      "event_type": "trade_intent",
      "symbol": "AAPL",
      "side": "buy",
      "qty": 10,
      "idempotency_key": "<agent_id>:trade_intent:<sha256>",
      "created_at": "2026-05-11T22:00:00Z"
    }
  ]
}
```

Fields above are the **complete allowlist** — the controller's
`serialize_event/1` never serializes the raw payload jsonb. If you find
yourself wanting a field that isn't here, the right move is to add it to the
allowlist via a PR, not to read it out-of-band.

### Idempotency

`GET /api/v1/triggers/pending` **claims** each returned event by setting its
status to `delivered` atomically (`SELECT FOR UPDATE SKIP LOCKED` → `UPDATE`).
If two runners poll concurrently, each event surfaces in exactly one
response. The `idempotency_key` is a deterministic hash of the trade intent;
if AgentRunner re-emits the same intent, the duplicate is collapsed at the
unique-index level rather than producing a second event.

## Error handling

| Status | Meaning | What the runner does |
|--------|---------|----------------------|
| `200`  | Events returned (possibly empty) | Process each event, then re-poll. |
| `204`  | `ack` accepted | Continue. |
| `401`  | Bad/missing `Authorization` header | Stop. Check the agent token. |
| `402`  | `POST /api/v1/trades` from a `per_trade` agent without an `X-Payment-Receipt` | Pay the fee via kpass, then **retry the exact same trade body with the `X-Payment-Receipt` header added** (CyberSec ask 7, msg 9140). Do **not** re-issue a different or re-randomized trade — that bypasses the idempotency guard on `TradeExecutionWorker` and can produce duplicate broker orders. |
| `404`  | `ack` for an event id this agent does not own (or that does not exist) | Skip. The API intentionally collapses both cases to 404 to prevent cross-agent enumeration. |
| `409`  | `X-Payment-Receipt` replay — KAH has already logged this receipt | Treat as success and skip. The fee is already booked. |
| `429`  | Rate-limited | Back off (exponential, ≥1s start). The endpoint enforces a per-agent cap on the same limiter as the trade endpoint. |
| `503`  | Vault not configured on this KAH instance | Stop. The platform is in a dev mode and is not accepting per-trade flows. |

**Broker-side failure must not result in an `ack`.** If the broker returns
an error or the order rejects, leave the event unacked — the dashboard will
show it as still pending and the user can manually intervene. Re-running
the poll loop will not surface the event a second time (it has already been
claimed) so the surface for a hung event is the dashboard, not the API.

## Payment rail behavior

- `payment_rail = "none"` — KAH does not return triggers for this agent
  (legacy direct-Oban dispatch still applies). The poll endpoint always
  returns `[]`.
- `payment_rail = "subscription"` — billing handled out-of-band (Stripe,
  post-hackathon). The trade endpoint does not return 402.
- `payment_rail = "per_trade"` — triggers flow through this endpoint, every
  trade returns 402 until a valid `X-Payment-Receipt` is presented, and
  every accepted trade writes a row to `fee_accruals` (audit-only).

## Where this runbook does NOT belong

- Anywhere broker credentials, kpass JWTs, Passport session material, or
  any other secret would need to live. The runbook only references the
  agent api_token (which is itself a placeholder above) and the public
  vault address (loaded from `VaultConfig.address/0` server-side; the user
  reads it off the linking panel).
- In a deployed binary that KAH operates. This is a doc for **user
  machines**.

## Next steps

- PR-X (separate, queued): server-side cryptographic verification of the
  `X-Payment-Receipt` against the vault address. Until that lands, accepted
  receipts emit a `Logger.warning("x402-unsigned-accept TODO …")` and the
  audit row is written but the signature is **not** verified server-side.
- A first-class Claude Code skill that wraps the poll loop is a reasonable
  follow-up — the doc-first approach in this PR is deliberate to keep PR-7
  small for the hackathon timeline.
