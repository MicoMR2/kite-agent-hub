defmodule KiteAgentHub.TradingPlatforms.OrderPayloadTest do
  use ExUnit.Case, async: true

  alias KiteAgentHub.TradingPlatforms.{AlpacaClient, KalshiClient, OandaClient}
  alias KiteAgentHub.Workers.TradeExecutionWorker

  test "Alpaca order body supports option contract limit orders" do
    body =
      AlpacaClient.order_body("AAPL260117C00100000", 1, "buy", %{
        "order_type" => "limit",
        "limit_price" => "1.05",
        "time_in_force" => "day"
      })

    assert body["symbol"] == "AAPL260117C00100000"
    assert body["qty"] == "1"
    assert body["side"] == "buy"
    assert body["type"] == "limit"
    assert body["limit_price"] == "1.05"
    assert body["time_in_force"] == "day"
  end

  test "option contract symbols route to Alpaca" do
    assert TradeExecutionWorker.detect_platform("AAPL260117C00100000") == "alpaca"
  end

  test "Kalshi order body supports reduce-only early exits" do
    {:ok, body} =
      KalshiClient.order_body("KXTEST-26JAN01-YES", "yes", 2, "0.56", %{
        "action" => "sell",
        "time_in_force" => "immediate_or_cancel"
      })

    assert body["action"] == "sell"
    assert body["side"] == "yes"
    assert body["count"] == 2
    assert body["yes_price"] == 56
    assert body["no_price"] == 44
    assert body["reduce_only"] == true
    assert body["time_in_force"] == "immediate_or_cancel"
  end

  test "OANDA practice order body supports protective order fields" do
    body =
      OandaClient.practice_order_body("EUR_USD", -100, %{
        "order_type" => "limit",
        "price" => "1.0800",
        "position_fill" => "reduce_only",
        "take_profit_price" => "1.0600",
        "stop_loss_price" => "1.1000",
        "trailing_stop_distance" => "0.0050",
        "client_order_id" => "agent-exit-1"
      })

    order = body["order"]
    assert order["type"] == "LIMIT"
    assert order["instrument"] == "EUR_USD"
    assert order["units"] == "-100"
    assert order["price"] == "1.0800"
    assert order["positionFill"] == "REDUCE_ONLY"
    assert order["takeProfitOnFill"]["price"] == "1.0600"
    assert order["stopLossOnFill"]["price"] == "1.1000"
    assert order["trailingStopLossOnFill"]["distance"] == "0.0050"
    assert order["clientExtensions"]["id"] == "agent-exit-1"
  end
end
