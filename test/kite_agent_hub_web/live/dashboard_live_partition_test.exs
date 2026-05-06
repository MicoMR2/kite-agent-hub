defmodule KiteAgentHubWeb.DashboardLivePartitionTest do
  @moduledoc """
  Coverage for `DashboardLive.partition_by_feed/1` — the helper that
  decides whether a position symbol streams via Alpaca's :stocks feed
  (IEX), :crypto feed (v1beta3/crypto/us), or :options feed
  (v1beta1/indicative). Sending a symbol to the wrong feed silently
  drops the subscription with no error visible to the user, so this
  routing has to be exact.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHubWeb.DashboardLive

  describe "partition_by_feed/1" do
    test "slash-form crypto routes to crypto feed" do
      assert DashboardLive.partition_by_feed(["BTC/USD", "ETH/USD", "SOL/USD"]) ==
               {[], ["BTC/USD", "ETH/USD", "SOL/USD"], []}
    end

    test "legacy concatenated crypto routes to crypto feed" do
      assert DashboardLive.partition_by_feed(["BTCUSD", "ETHUSD"]) ==
               {[], ["BTCUSD", "ETHUSD"], []}
    end

    test "USDC pairs route to crypto" do
      assert DashboardLive.partition_by_feed(["USDC/USD", "BTCUSDC"]) ==
               {[], ["USDC/USD", "BTCUSDC"], []}
    end

    test "regular equity tickers route to stocks" do
      assert DashboardLive.partition_by_feed(["AAPL", "SPY", "NVDA", "TSLA"]) ==
               {["AAPL", "SPY", "NVDA", "TSLA"], [], []}
    end

    test "OCC option symbols route to options feed" do
      occ = ["AAPL260117C00100000", "SPY261219P00450000", "TSLA260620C00250000"]
      assert DashboardLive.partition_by_feed(occ) == {[], [], occ}
    end

    test "mixed input partitions correctly" do
      input = [
        "AAPL",
        "BTC/USD",
        "SPY",
        "ETHUSD",
        "MSFT",
        "AAPL260117C00100000"
      ]

      assert DashboardLive.partition_by_feed(input) ==
               {["AAPL", "SPY", "MSFT"], ["BTC/USD", "ETHUSD"], ["AAPL260117C00100000"]}
    end

    test "short USD-suffix tickers (5 chars or less) stay on stocks" do
      # A hypothetical 5-char ticker ending in USD (rare but possible)
      # should not be misclassified — the heuristic only treats 6+ char
      # USD-ending strings as crypto.
      assert DashboardLive.partition_by_feed(["XUSD"]) == {["XUSD"], [], []}
    end

    test "empty list returns three empty lists" do
      assert DashboardLive.partition_by_feed([]) == {[], [], []}
    end
  end
end
