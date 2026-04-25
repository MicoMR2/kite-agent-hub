# Handoff: Stuck Trades And OANDA Routing

## Context

This handoff covers a local, uncommitted patch on branch `feat/codex-inline-env`.
The work addresses two issues:

- Stuck Alpaca trades/orders, especially symbols like `HAL` and `SLB`, were hard for agents to diagnose because `/trades` did not expose broker routing fields.
- OANDA forex attempts could be sent through the normal equity/crypto trade payload, creating confusing KAH-side records instead of using the OANDA practice execution path.

Nothing has been committed, pushed, merged, or deployed by Codex.

## Changed Files

- `docs/AGENT_PLAYBOOK.md`
- `lib/kite_agent_hub/trading.ex`
- `lib/kite_agent_hub/workers/stuck_trade_sweeper.ex`
- `lib/kite_agent_hub_web/controllers/api/trades_controller.ex`
- `plugins/kite-agent-hub-agent/prompts/trading-agent.codex.md`
- `test/kite_agent_hub/trading_cancel_test.exs`
- `test/kite_agent_hub_web/controllers/api/trades_controller_test.exs`

## What Changed

- Scoped `Trading.auto_cancel_stuck_trades/2` with optional `agent_id: id`.
- Updated `archive_agent/1` and `StuckTradeSweeper` to pass the target agent id so cleanup for one agent cannot cancel unrelated open trades from another agent in the same org-owner RLS scope.
- Added `platform` and `platform_order_id` to `/api/v1/trades` serialization so agents can match KAH trade records to live Alpaca broker orders.
- Added `provider: "oanda"` alias normalization to `oanda_practice`.
- Added a guard that rejects forex-shaped symbols like `EUR_USD` when sent through the normal equity/crypto payload. Error: `forex trades require provider=oanda_practice and symbol like EUR_USD`.
- Updated Trade Agent prompt and canonical agent playbook with `/portfolio`, `/forex/portfolio`, `/broker/orders`, Alpaca stuck-order cleanup, and the correct OANDA practice payload.

## OANDA Behavior To Preserve

OANDA execution currently uses the paper-provider path:

```json
{
  "provider": "oanda_practice",
  "symbol": "EUR_USD",
  "side": "buy",
  "units": 100,
  "reason": "EUR momentum setup"
}
```

Only Trade Agent should be allowed to submit this payload. Current OANDA execution is practice mode only.

Official OANDA docs confirm REST access and market orders through `POST /v3/accounts/{accountID}/orders`. OANDA instruments use names like `EUR_USD`, and signed units represent buy/sell direction.

Docs:

- https://developer.oanda.com/rest-live-v20/introduction/
- https://developer.oanda.com/rest-live-v20/order-ep/

## Verification Already Run

Command:

```bash
mix test test/kite_agent_hub/trading_cancel_test.exs test/kite_agent_hub_web/controllers/api/trades_controller_test.exs
```

Result:

```text
8 tests, 0 failures
```

Known unrelated compile warnings remain in existing files, mostly grouped LiveView callbacks, unused aliases, and Alpaca client optional defaults.

## Review Checklist For Next Agent

- Review the diff with `git diff` and include the untracked test file in the PR.
- Confirm prompt files still contain no single quotes because `CodexPrompts.combined_block/1` wraps them in single-quoted shell strings.
- Run the focused test command above.
- Prefer running the broader relevant controller/context tests before PR if time allows.
- Do not merge directly to main. Open a PR, check preview, then merge only after Mico approves.

## Post-Deploy Cleanup Still Needed

This patch makes the system safer and gives agents the tools to diagnose stale orders, but it does not directly modify production data.

After deploy, check live broker state:

1. Use a Trade Agent token to call `GET /api/v1/broker/orders?status=open`.
2. Look for stale live Alpaca orders for `HAL`, `SLB`, or any other blocked symbols.
3. Cancel stale live Alpaca orders with `DELETE /api/v1/broker/orders/<order_id>`.
4. Recheck `GET /api/v1/portfolio` against Alpaca as the live broker source of truth.
5. Recheck `GET /api/v1/trades?status=open` to verify the KAH audit trail is no longer misleading.

## Suggested Commit Message

```text
Fix stuck trade cleanup scope and OANDA routing guidance
```
