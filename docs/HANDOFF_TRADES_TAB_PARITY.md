# Handoff: Trades Tab Parity

## Context

This handoff covers a local, uncommitted patch on branch `feat/codex-inline-env`.
The issue: in the Trades tab, selecting `TradeTestAgent` showed `0.00` P&L for rows even though the dashboard had realized P&L, and the `Chain` column showed dashes even when settled trades had Kite attestation receipts.

Nothing has been committed, pushed, merged, or deployed by Codex.

## Changed Files

- `lib/kite_agent_hub/trading.ex`
- `lib/kite_agent_hub_web/live/trades_live.ex`
- `test/kite_agent_hub_web/live/trades_live_test.exs`

## What Changed

- Added `Trading.list_trades_with_display_pnl/2`.
- The helper computes row-level `display_pnl` for settled sell rows using FIFO from the agent's settled trade fills.
- The calculation avoids rendering historical `realized_pnl = 0` settlement placeholders as real profit/loss.
- Open rows and buy rows keep `display_pnl = nil` because they do not represent realized P&L.
- Updated the Trades tab to render `display_pnl` instead of raw `realized_pnl`.
- Added a Platform column so the table shows where trades executed, such as `ALPACA` or `KITE`.
- Updated the Chain column to link `attestation_tx_hash` first, with a fallback to the older `tx_hash` when present.
- Added LiveView coverage proving the Trades tab shows computed P&L, platform, and the Kite attestation URL.

## Verification Already Run

Command:

```bash
mix test test/kite_agent_hub_web/live/trades_live_test.exs test/kite_agent_hub/trading_cancel_test.exs test/kite_agent_hub_web/controllers/api/trades_controller_test.exs
```

Result:

```text
10 tests, 0 failures
```

Known unrelated compile warnings remain in existing files, mostly grouped LiveView callbacks, unused aliases, and Alpaca client optional defaults.

## Review Checklist For Next Agent

- Review only the Trades tab parity diff if this task is being handled separately from stuck-trades/OANDA.
- Include the untracked LiveView test file in the PR.
- Confirm the Trades tab still renders acceptably at desktop/tablet widths after the Platform column was added.
- Confirm settled trades with `attestation_tx_hash` show a Kite chain link instead of `—`.
- Confirm computed P&L appears on closed sell rows and open/buy rows do not falsely show realized P&L.
- Run the focused test command above.
- Do not merge directly to main. Open a PR, check preview, then merge only after Mico approves.

## Suggested Commit Message

```text
Fix Trades tab P&L and attestation parity
```
