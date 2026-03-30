defmodule KiteAgentHub.Kite.VaultABI do
  @moduledoc """
  Manual ABI encoding for TradingAgentVault contract calls.

  Function selectors are the first 4 bytes of keccak256(function_signature).
  Arguments are ABI-encoded as 32-byte padded big-endian values.

  Supported calls:
    - openPosition(uint256 marketId, uint8 side, uint256 size, uint256 price)
    - closePosition(uint256 positionId)
    - depositFunds()  [payable, no args]

  These match the Kite AI TradingAgentVault interface used in the hackathon.
  If the deployed contract has a different ABI, update the selectors below.

  Selector verification:
    openPosition:  keccak256("openPosition(uint256,uint8,uint256,uint256)")[0..3]
    closePosition: keccak256("closePosition(uint256)")[0..3]
  """

  # Pre-computed 4-byte selectors (keccak256 of function signature)
  # openPosition(uint256,uint8,uint256,uint256)
  @open_position_selector ExKeccak.hash_256("openPosition(uint256,uint8,uint256,uint256)")
                          |> binary_part(0, 4)
                          |> Base.encode16(case: :lower)

  # closePosition(uint256)
  @close_position_selector ExKeccak.hash_256("closePosition(uint256)")
                           |> binary_part(0, 4)
                           |> Base.encode16(case: :lower)

  @doc """
  Encode an openPosition call.

  - market_id: integer ID for the market (0 = ETH-USDC on Kite testnet)
  - side: 0 = long, 1 = short
  - size_wei: position size in wei (contracts * 10^18)
  - price_wei: fill price in wei (price_usd * 10^18)

  Returns hex string with 0x prefix.
  """
  def encode_open_position(market_id, side, size_wei, price_wei) do
    "0x" <>
      @open_position_selector <>
      pad_uint256(market_id) <>
      pad_uint256(side) <>
      pad_uint256(size_wei) <>
      pad_uint256(price_wei)
  end

  @doc """
  Encode a closePosition call.
  - position_id: on-chain position ID (from trade_id_onchain)
  """
  def encode_close_position(position_id) do
    "0x" <> @close_position_selector <> pad_uint256(position_id)
  end

  @doc """
  Build calldata for a TradeRecord.
  Converts the trade's action/side/contracts/fill_price to ABI-encoded calldata.
  """
  def calldata_for_trade(trade) do
    market_id = market_to_id(trade.market)
    side = side_to_int(trade.side, trade.action)
    size_wei = round(trade.contracts * 1.0e18)
    price_wei = round(Decimal.to_float(trade.fill_price) * 1.0e18)

    encode_open_position(market_id, side, size_wei, price_wei)
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  # Kite testnet market IDs (adjust if the hackathon uses different IDs)
  defp market_to_id("ETH-USDC"), do: 0
  defp market_to_id("BTC-USDC"), do: 1
  defp market_to_id("KITE-USDC"), do: 2
  defp market_to_id(_), do: 0

  # side: 0 = long (buy), 1 = short (sell)
  defp side_to_int(_, "buy"), do: 0
  defp side_to_int(_, "sell"), do: 1
  defp side_to_int("long", _), do: 0
  defp side_to_int("short", _), do: 1
  defp side_to_int(_, _), do: 0

  # ABI uint256 = 32-byte big-endian zero-padded hex
  defp pad_uint256(0), do: String.duplicate("0", 64)

  defp pad_uint256(n) when is_integer(n) and n > 0 do
    hex = Integer.to_string(n, 16)
    String.pad_leading(hex, 64, "0") |> String.downcase()
  end

  defp pad_uint256(n) when is_float(n), do: pad_uint256(round(n))
end
