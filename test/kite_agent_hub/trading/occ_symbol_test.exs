defmodule KiteAgentHub.Trading.OccSymbolTest do
  use ExUnit.Case, async: true

  alias KiteAgentHub.Trading.OccSymbol

  test "matches valid OCC symbols" do
    assert OccSymbol.match?("AAPL260117C00100000")
    assert OccSymbol.match?("SPY260117P00400000")
    # Maximum 6-letter root (e.g. BRKB and 5-char tickers)
    assert OccSymbol.match?("BRKB260117C00100000")
    # Single-letter root
    assert OccSymbol.match?("F260117C00010000")
  end

  test "rejects equity tickers" do
    refute OccSymbol.match?("AAPL")
    refute OccSymbol.match?("SPY")
  end

  test "rejects crypto pairs" do
    refute OccSymbol.match?("BTCUSD")
    refute OccSymbol.match?("BTC-USDC")
  end

  test "rejects malformed contract symbols" do
    # Wrong CP indicator
    refute OccSymbol.match?("AAPL260117X00100000")
    # Wrong strike length (7 digits)
    refute OccSymbol.match?("AAPL260117C0010000")
    # Wrong date length (5 digits)
    refute OccSymbol.match?("AAPL26011C00100000")
    # Lowercase root
    refute OccSymbol.match?("aapl260117C00100000")
  end

  test "rejects non-binary input gracefully" do
    refute OccSymbol.match?(nil)
    refute OccSymbol.match?(123)
    refute OccSymbol.match?(%{})
  end
end
