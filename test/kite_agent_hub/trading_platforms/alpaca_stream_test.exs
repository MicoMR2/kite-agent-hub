defmodule KiteAgentHub.TradingPlatforms.AlpacaStreamTest do
  @moduledoc """
  Coverage for the pure parts of `AlpacaStream` — topic naming and the
  Phoenix.PubSub broadcast contract for incoming feed events. The actual
  WebSocket connection / WebSockex callbacks need a live Alpaca endpoint
  and are not unit-testable in isolation.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.TradingPlatforms.AlpacaStream

  describe "topic/2" do
    test "namespaces by feed and symbol" do
      assert AlpacaStream.topic(:stocks, "AAPL") == "alpaca_stream:stocks:AAPL"
      assert AlpacaStream.topic(:crypto, "BTC/USD") == "alpaca_stream:crypto:BTC/USD"
      assert AlpacaStream.topic(:news, "ALL") == "alpaca_stream:news:ALL"
    end
  end

  describe "subscribe/2" do
    setup do
      # ConnCase auto-starts PubSub; ExUnit case does not, so subscribe to
      # the named PubSub the module hardcodes. PubSub is started at app boot.
      :ok
    end

    test "trade event arrives at subscribers" do
      AlpacaStream.subscribe(:stocks, "AAPL")

      Phoenix.PubSub.broadcast(
        KiteAgentHub.PubSub,
        "alpaca_stream:stocks:AAPL",
        %{type: "t", symbol: "AAPL", price: 187.42, size: 100, ts: "2026-05-04T12:00:00Z"}
      )

      assert_receive %{type: "t", symbol: "AAPL", price: 187.42}, 200
    end

    test "news ALL channel receives news events" do
      AlpacaStream.subscribe(:news, "ALL")

      Phoenix.PubSub.broadcast(
        KiteAgentHub.PubSub,
        "alpaca_stream:news:ALL",
        %{type: "n", id: 1, headline: "test"}
      )

      assert_receive %{type: "n", id: 1, headline: "test"}, 200
    end

    test "wrong feed/symbol pair does NOT receive events" do
      AlpacaStream.subscribe(:stocks, "AAPL")

      Phoenix.PubSub.broadcast(
        KiteAgentHub.PubSub,
        "alpaca_stream:stocks:MSFT",
        %{type: "t", symbol: "MSFT"}
      )

      refute_receive %{type: "t", symbol: "MSFT"}, 100
    end
  end
end
