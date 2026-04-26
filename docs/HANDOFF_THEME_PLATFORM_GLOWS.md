# Handoff: Theme Toggle And Platform Glows

## Context

This handoff covers a local, uncommitted patch in the active repo:

`/Users/damicomartin/kite-agent-hub`

Note: paths inside the Phoenix app use underscores, such as `lib/kite_agent_hub_web/...`, but they are still inside the active `kite-agent-hub` repo.

The task: add light mode plus dark mode support, and make trading platform UI elements use consistent glowing outline colors.

Nothing has been committed, pushed, merged, or deployed by Codex.

## Changed Files

- `assets/css/app.css`
- `lib/kite_agent_hub_web/components/layouts.ex`
- `lib/kite_agent_hub_web/components/layouts/root.html.heex`
- `lib/kite_agent_hub_web/live/dashboard_live.ex`
- `lib/kite_agent_hub_web/live/trades_live.ex`
- `test/kite_agent_hub_web/live/trades_live_test.exs`

## What Changed

- Added a floating theme toggle to the shared app layout.
- Updated the root theme bootstrap so `system`, `light`, and `dark` modes always resolve to a real `data-theme` value before CSS loads.
- Persisted explicit light/dark selections in `localStorage` and made `system` follow `prefers-color-scheme`.
- Added a light-mode compatibility layer in `app.css` to make existing hardcoded dark Tailwind classes readable without rewriting every LiveView.
- Added platform glow utility classes:
  - Alpaca: yellow via `kah-platform-alpaca`
  - Kalshi: green via `kah-platform-kalshi`
  - Polymarket: blue via `kah-platform-polymarket`
  - Forex: orange via `kah-platform-forex`
- Updated Trades tab platform badges to use the platform utility classes.
- Updated Dashboard platform tabs for Alpaca, Kalshi, Polymarket, and ForEx to use glowing pill outlines.
- Added a test assertion that Alpaca rows render with `kah-platform-alpaca` instead of the prior blue/cyan look.

## Verification Already Run

Commands:

```bash
mix test test/kite_agent_hub_web/live/trades_live_test.exs
mix assets.build
```

Results:

```text
2 tests, 0 failures
assets build passed
```

Known unrelated compile warnings remain in existing files, mostly grouped LiveView callbacks, unused aliases, and Alpaca client optional defaults.

## Review Checklist For Next Agent

- Review the diff from the active repo only: `/Users/damicomartin/kite-agent-hub`.
- Confirm the theme toggle is visible but not blocking important controls on desktop and mobile.
- Manually click `system`, `light`, and `dark` in the browser and refresh to confirm persistence.
- Check the Trades tab: Alpaca badges should be yellow, not blue.
- Check Dashboard platform tabs: Alpaca yellow, Kalshi green, Polymarket blue, ForEx orange.
- Check at least Dashboard, Trades, API Keys, and Agents pages in light mode for readability because the compatibility layer is broad.
- Run the verification commands above.
- Do not merge directly to main. Open a PR, check preview, then merge only after Mico approves.

## Suggested Commit Message

```text
Add theme toggle and platform glow colors
```
