defmodule KiteAgentHub.TradingPlatforms.KalshiIocPreflightTest do
  @moduledoc """
  Unit-level coverage for the IOC pre-flight surface added in PR #305.

  The full pre-flight + place_order pipe requires a live Kalshi
  connection (or an HTTP mock layer that does not exist in this
  codebase yet), so we cover only the pure pieces here:

    * `valid_ticker?/1` — the regex that gates URL interpolation.
    * Price-bump arithmetic via the public `place_order` only when a
      bad ticker is supplied (errors before any network call).

  The orderbook side of the pre-flight is exercised against live
  Kalshi paper in dev, not in CI.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.TradingPlatforms.KalshiClient

  describe "valid_ticker?/1" do
    test "accepts canonical Kalshi tickers" do
      assert KalshiClient.valid_ticker?("BTCZ-24DEC2031-B80000")
      assert KalshiClient.valid_ticker?("KXMAYORNYC-24-AC")
      assert KalshiClient.valid_ticker?("AB1")
    end

    test "rejects path-traversal attempts" do
      refute KalshiClient.valid_ticker?("../foo")
      refute KalshiClient.valid_ticker?("/admin/users")
      refute KalshiClient.valid_ticker?("..%2Fetc")
    end

    test "rejects query-string injection" do
      refute KalshiClient.valid_ticker?("BTCZ?limit=999")
      refute KalshiClient.valid_ticker?("BTCZ&admin=1")
      refute KalshiClient.valid_ticker?("BTCZ#frag")
    end

    test "rejects whitespace and control characters" do
      refute KalshiClient.valid_ticker?("BTC Z")
      refute KalshiClient.valid_ticker?("BTC\nZ")
      refute KalshiClient.valid_ticker?("")
    end

    test "rejects non-binary input" do
      refute KalshiClient.valid_ticker?(nil)
      refute KalshiClient.valid_ticker?(123)
      refute KalshiClient.valid_ticker?(["BTCZ-24DEC2031-B80000"])
    end

    test "rejects tickers over the 64-char cap" do
      refute KalshiClient.valid_ticker?(String.duplicate("A", 65))
      assert KalshiClient.valid_ticker?(String.duplicate("A", 64))
    end
  end

  describe "place_order/8 input gate" do
    test "returns {:error, _} on an invalid ticker without making an HTTP call" do
      # No PEM, no key — if the function reached the HTTP path it
      # would crash on the signing step. The fact that we get a
      # clean {:error, _} back proves the ticker check fired first.
      assert {:error, "invalid kalshi ticker"} =
               KalshiClient.place_order(nil, nil, "../bad/ticker", "yes", 1, 50, "paper")
    end
  end
end
