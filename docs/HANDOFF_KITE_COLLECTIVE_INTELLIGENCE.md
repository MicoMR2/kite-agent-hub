# Handoff: Kite Collective Intelligence

Branch: `damico/kite-collective-intelligence`

## Scope

Adds workspace-scoped opt-in for **Kite Collective Intelligence** or KCI.
KCI lets agents use anonymized, bucketed trade outcome lessons from opted-in
workspaces while keeping user-identifying data out of the shared learning
table.

## Product Behavior

- KCI is disabled by default.
- Users enable or disable KCI per workspace at
  `/users/settings/workspace`.
- A user can separate KCI-enabled agents and non-KCI agents by placing them in
  different workspaces.
- Turning KCI off purges that workspace's prior anonymized contributions and
  stops future contribution or use.
- `/api/v1/agents/me` now tells agents whether KCI is enabled for their
  workspace.
- `/api/v1/collective-intelligence` returns aggregate lessons only when the
  calling agent belongs to an opted-in workspace.

## Privacy Boundary

The `collective_trade_insights` table intentionally does not store:

- user IDs
- agent IDs
- organization IDs
- exact trade IDs
- raw chats
- broker credentials
- API tokens
- raw strategy text or free-form trade reasons

It stores only:

- salted source hashes for dedupe and opt-out purge
- agent type
- platform
- market class
- side/action
- terminal status/outcome bucket
- notional bucket
- hold-time bucket
- observed week

## Files Changed

- `priv/repo/migrations/20260425220000_create_collective_intelligence.exs`
- `lib/kite_agent_hub/collective_intelligence.ex`
- `lib/kite_agent_hub/collective_intelligence/trade_insight.ex`
- `lib/kite_agent_hub/orgs.ex`
- `lib/kite_agent_hub/orgs/organization.ex`
- `lib/kite_agent_hub/trading.ex`
- `lib/kite_agent_hub/trading/agent_context.ex`
- `lib/kite_agent_hub_web/live/workspace_live.ex`
- `lib/kite_agent_hub_web/controllers/api/collective_intelligence_controller.ex`
- `lib/kite_agent_hub_web/controllers/api/trades_controller.ex`
- `lib/kite_agent_hub_web/router.ex`
- `plugins/kite-agent-hub-agent/prompts/*.codex.md`
- `docs/AGENT_PLAYBOOK.md`
- `test/kite_agent_hub/collective_intelligence_test.exs`
- `test/kite_agent_hub_web/controllers/api/collective_intelligence_controller_test.exs`

## Legal/Product Follow-Up

Before promoting this as public-facing production behavior, add matching copy
to Terms and Privacy Policy:

- KCI is optional and workspace scoped.
- KCI uses anonymized and bucketed trade outcome data from opted-in workspaces.
- KCI does not guarantee profit.
- KCI is decision-support context, not financial advice.
- Disabling KCI stops future contribution and purges that workspace's prior
  anonymized contribution rows.

## Verification

Ran:

```bash
MIX_ENV=test mix ecto.migrate
mix test test/kite_agent_hub/collective_intelligence_test.exs test/kite_agent_hub_web/controllers/api/collective_intelligence_controller_test.exs test/kite_agent_hub_web/controllers/api/trades_controller_test.exs
mix assets.build
mix test
grep -R "'" plugins/kite-agent-hub-agent/prompts/*.codex.md
git diff --check
```

Results:

- KCI targeted tests: `7 tests, 0 failures`
- `mix assets.build`: passed
- Prompt single-quote check: no matches
- `git diff --check`: clean

Full `mix test` currently reports `172 tests, 15 failures`. The failures are
pre-existing unrelated auth/onboarding/settings expectations and one Kalshi
market scorer fixture expectation, not KCI-specific test failures.

Known unrelated compile warnings remain in existing LiveView and edge-score
modules.
