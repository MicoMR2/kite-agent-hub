# Handoff: Broker Trading Paths

Branch: `damico/broker-trading-paths`

## Scope

Adds safer broker-native order support for Trade Agent routing across Alpaca,
Kalshi, and OANDA practice.

## What changed

- Alpaca now routes OCC option contract symbols such as `AAPL260117C00100000`
  to Alpaca instead of falling through to Kite.
- Alpaca order payloads can pass optional fields such as `order_type`,
  `limit_price`, `stop_price`, `trail_price`, `trail_percent`, `order_class`,
  `take_profit`, `stop_loss`, and `client_order_id`.
- Kalshi is now accepted through `POST /api/v1/trades` with
  `provider: "kalshi"` and supports `buy` or `sell` for `yes` or `no`
  contracts.
- Kalshi sell orders default to `reduce_only: true` to support early exits
  without accidentally opening the opposite exposure.
- Kalshi optional controls now pass through, including `time_in_force`,
  `buy_max_cost`, `post_only`, `reduce_only`, `client_order_id`,
  `expiration_ts`, and self-trade prevention fields.
- OANDA practice orders now support optional v20 controls such as `order_type`,
  `price`, `time_in_force`, `position_fill`, `take_profit_price`,
  `stop_loss_price`, `trailing_stop_distance`, and `client_order_id`.
- Trade Agent prompt and `docs/AGENT_PLAYBOOK.md` now include Alpaca options,
  Kalshi, and OANDA payload examples.

## Safety notes

- Only `agent_type: "trading"` can submit trades. Research and conversational
  agents remain blocked from execution.
- OANDA live order dispatch remains intentionally disabled. This patch only
  expands OANDA practice-mode order controls.
- Kalshi cannot be made to always profit. This patch adds reduce-only early
  exits and risk controls, but prices and liquidity still decide the result.
- Alpaca options still depend on the broker account having the required options
  approval level and buying power.

## Official docs used

- Alpaca Options Trading:
  https://docs.alpaca.markets/docs/options-trading
- Kalshi Create Order:
  https://docs.kalshi.com/api-reference/orders/create-order
- OANDA v20 Order Definitions:
  https://developer.oanda.com/rest-live-v20/order-df/

## Verification

Ran:

```bash
mix format lib/kite_agent_hub/workers/trade_execution_worker.ex lib/kite_agent_hub/workers/paper_execution_worker.ex lib/kite_agent_hub_web/controllers/api/trades_controller.ex lib/kite_agent_hub/trading_platforms/alpaca_client.ex lib/kite_agent_hub/trading_platforms/kalshi_client.ex lib/kite_agent_hub/trading_platforms/oanda_client.ex lib/kite_agent_hub/oanda.ex test/kite_agent_hub/trading_platforms/order_payload_test.exs docs/AGENT_PLAYBOOK.md plugins/kite-agent-hub-agent/prompts/trading-agent.codex.md
mix test test/kite_agent_hub/trading_platforms/order_payload_test.exs test/kite_agent_hub_web/controllers/api/trades_controller_test.exs
```

Result: `6 tests, 0 failures`.

Existing unrelated compile warnings remain in LiveView modules and edge-score
worker modules.
