defmodule KiteAgentHub.Kite.VaultABITest do
  use ExUnit.Case, async: true

  alias KiteAgentHub.Kite.VaultABI

  describe "encode_open_position/4" do
    test "returns 0x-prefixed hex string" do
      result =
        VaultABI.encode_open_position(
          0,
          0,
          1_000_000_000_000_000_000,
          3_250_000_000_000_000_000_000
        )

      assert String.starts_with?(result, "0x")
    end

    test "has correct length: 4-byte selector + 4 × 32-byte args = 132 bytes = 268 hex chars with 0x" do
      result = VaultABI.encode_open_position(0, 0, 1, 1)
      # "0x" + 8 (selector) + 4*64 (args) = 2 + 8 + 256 = 266 chars
      assert byte_size(result) == 266
    end

    test "long and short produce different calldata" do
      long = VaultABI.encode_open_position(0, 0, 1_000, 3_000)
      short = VaultABI.encode_open_position(0, 1, 1_000, 3_000)
      refute long == short
    end
  end

  describe "calldata_for_trade/1" do
    test "produces valid calldata from a trade struct" do
      trade = %{
        market: "ETH-USDC",
        side: "long",
        action: "buy",
        contracts: 5,
        fill_price: Decimal.new("3250.50")
      }

      result = VaultABI.calldata_for_trade(trade)
      assert String.starts_with?(result, "0x")
      assert byte_size(result) == 266
    end

    test "buy and sell produce different calldata (side encoding differs)" do
      buy_trade = %{
        market: "ETH-USDC",
        side: "long",
        action: "buy",
        contracts: 1,
        fill_price: Decimal.new("3000")
      }

      sell_trade = %{
        market: "ETH-USDC",
        side: "short",
        action: "sell",
        contracts: 1,
        fill_price: Decimal.new("3000")
      }

      assert VaultABI.calldata_for_trade(buy_trade) != VaultABI.calldata_for_trade(sell_trade)
    end

    test "price precision is maintained at high values without float drift" do
      # 3250.999999999999 should encode distinctly from 3251.0
      trade_a = %{
        market: "ETH-USDC",
        side: "long",
        action: "buy",
        contracts: 1,
        fill_price: Decimal.new("3250.999999999999")
      }

      trade_b = %{
        market: "ETH-USDC",
        side: "long",
        action: "buy",
        contracts: 1,
        fill_price: Decimal.new("3251.000000000000")
      }

      assert VaultABI.calldata_for_trade(trade_a) != VaultABI.calldata_for_trade(trade_b)
    end
  end
end
