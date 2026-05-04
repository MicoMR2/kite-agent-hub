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

  test "Alpaca options orders never include extended_hours (Alpaca rejects it)" do
    body =
      AlpacaClient.order_body("AAPL260117C00100000", 1, "buy", %{
        "order_type" => "market",
        "extended_hours" => true
      })

    refute Map.has_key?(body, "extended_hours")
  end

  test "Alpaca equity orders still pass through extended_hours" do
    body =
      AlpacaClient.order_body("SPY", 1, "buy", %{
        "order_type" => "market",
        "extended_hours" => true
      })

    assert body["extended_hours"] == true
  end

  test "Alpaca options orders truncate fractional qty to whole" do
    body =
      AlpacaClient.order_body("AAPL260117C00100000", 1.7, "buy", %{
        "order_type" => "market"
      })

    assert body["qty"] == "1"
  end

  test "Alpaca options orders coerce sub-1 fractional qty up to 1" do
    body =
      AlpacaClient.order_body("AAPL260117C00100000", 0.5, "buy", %{
        "order_type" => "market"
      })

    # Better to submit qty=1 (smallest legal option order) than 0 (Alpaca 422)
    # if an agent ever passes a sub-1 fractional by mistake.
    assert body["qty"] == "1"
  end

  test "Alpaca order_body sends notional and omits qty when notional is supplied" do
    body =
      AlpacaClient.order_body("AAPL", 0, "buy", %{
        "order_type" => "market",
        "notional" => "250.00"
      })

    assert body["notional"] == "250.00"
    refute Map.has_key?(body, "qty")
  end

  test "Alpaca order_body falls back to qty when notional is nil" do
    body =
      AlpacaClient.order_body("AAPL", 5, "buy", %{
        "order_type" => "market"
      })

    assert body["qty"] == "5"
    refute Map.has_key?(body, "notional")
  end

  test "Alpaca options orders ignore notional even if supplied (Alpaca rejects it)" do
    body =
      AlpacaClient.order_body("AAPL260117C00100000", 1, "buy", %{
        "order_type" => "market",
        "notional" => "250.00"
      })

    assert body["qty"] == "1"
    refute Map.has_key?(body, "notional")
  end

  test "Alpaca crypto fractional qty passes through unchanged" do
    body =
      AlpacaClient.order_body("BTCUSD", 0.001, "buy", %{
        "order_type" => "market"
      })

    assert body["qty"] == "0.001"
    assert body["time_in_force"] == "gtc"
  end

  test "Alpaca slash-format crypto picks gtc time_in_force" do
    # Without the slash-aware time_in_force_for/1 clause, "BTC/USD"
    # would have fallen through to "day" and Alpaca's crypto venue
    # would have rejected the order with code 42210000.
    for sym <- ["BTC/USD", "ETH/USD", "SOL/USD"] do
      body = AlpacaClient.order_body(sym, 0.001, "buy", %{"order_type" => "market"})
      assert body["time_in_force"] == "gtc", "#{sym} got #{body["time_in_force"]}"
      assert body["symbol"] == sym
    end
  end

  test "TradeExecutionWorker routes slash-format crypto to Alpaca" do
    assert TradeExecutionWorker.detect_platform("BTC/USD") == "alpaca"
    assert TradeExecutionWorker.detect_platform("ETH/USD") == "alpaca"
    assert TradeExecutionWorker.detect_platform("SOL/USD") == "alpaca"
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
    refute Map.has_key?(body, "no_price")
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

  test "OANDA close-position body defaults to ALL/ALL when no opts supplied" do
    assert OandaClient.close_position_body(%{}) ==
             %{"longUnits" => "ALL", "shortUnits" => "ALL"}
  end

  test "OANDA close-position body honors a single side and omits the other" do
    long_only = OandaClient.close_position_body(%{"long_units" => "ALL"})
    assert long_only == %{"longUnits" => "ALL"}

    short_only = OandaClient.close_position_body(%{"short_units" => "100"})
    assert short_only == %{"shortUnits" => "100"}
  end

  test "OANDA close-position body normalizes ALL/NONE casing and accepts decimals" do
    body =
      OandaClient.close_position_body(%{
        "longUnits" => "  all  ",
        "shortUnits" => "0.5"
      })

    assert body == %{"longUnits" => "ALL", "shortUnits" => "0.5"}
  end

  test "OANDA close-position body silently drops malformed unit strings" do
    body =
      OandaClient.close_position_body(%{
        "long_units" => "not-a-number",
        "short_units" => ""
      })

    # Both inputs collapse to nil, so the body falls back to default ALL/ALL
    assert body == %{"longUnits" => "ALL", "shortUnits" => "ALL"}
  end
end
