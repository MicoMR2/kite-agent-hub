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

  describe "parse/1" do
    test "extracts root, expiration, type, strike from a valid call" do
      assert {:ok, parsed} = OccSymbol.parse("AAPL260117C00100000")
      assert parsed.root == "AAPL"
      assert parsed.expiration_date == ~D[2026-01-17]
      assert parsed.option_type == :call
      assert parsed.strike == 100.0
    end

    test "extracts a valid put with fractional strike" do
      assert {:ok, parsed} = OccSymbol.parse("SPY260117P00450500")
      assert parsed.root == "SPY"
      assert parsed.option_type == :put
      assert parsed.strike == 450.5
    end

    test "handles single-letter root" do
      assert {:ok, %{root: "F", option_type: :call}} = OccSymbol.parse("F260117C00010000")
    end

    test "handles 5-character root (BRKB)" do
      assert {:ok, %{root: "BRKB"}} = OccSymbol.parse("BRKB260117C00100000")
    end

    test "rejects malformed contract symbols" do
      assert :error = OccSymbol.parse("AAPL")
      assert :error = OccSymbol.parse("not-an-occ")
      assert :error = OccSymbol.parse("AAPL260117X00100000")
    end

    test "rejects invalid embedded date" do
      # 260230 = Feb 30, 2026 — passes regex shape, fails Date.new
      assert :error = OccSymbol.parse("AAPL260230C00100000")
    end

    test "rejects non-binary input" do
      assert :error = OccSymbol.parse(nil)
      assert :error = OccSymbol.parse(123)
      assert :error = OccSymbol.parse(%{})
    end
  end
end
