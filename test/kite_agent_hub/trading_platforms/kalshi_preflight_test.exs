defmodule KiteAgentHub.TradingPlatforms.KalshiPreflightTest do
  @moduledoc """
  Hermetic coverage for the pre-trade validation decision logic
  added in PR-A. The HTTP-layer wrappers (`market/4`, `exchange_status/3`)
  are integration-tested against live Kalshi paper; here we drive
  `preflight_decision/2` directly with stubbed responses to cover
  the five reject cases CyberSec required (msg 10642 condition ⑥):

    * 404 on /markets/{ticker}                  → :ticker_not_found
    * market.status ∉ ["open","active"]         → :market_closed
    * exchange_active or trading_active = false → :exchange_closed
    * 429 (rate limit)                          → :validator_unavailable
    * timeout / transport error                 → :validator_unavailable

  Every reject case asserts a structured atom reason (CyberSec ③) so
  Kalshi response bodies + auth headers never leak into trade-worker
  logs (CyberSec ②). Reaching the :ok branch is the *only* state in
  which the worker can fall through to POST /portfolio/orders.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.TradingPlatforms.KalshiClient

  describe "preflight_decision/2 — happy path" do
    test "open market + active exchange returns :ok" do
      market = {:ok, %{ticker: "BTCZ-24DEC2031-B80000", status: "open"}}
      exchange = {:ok, %{exchange_active: true, trading_active: true}}

      assert :ok = KalshiClient.preflight_decision(market, exchange)
    end

    test "active (synonym) market + active exchange returns :ok" do
      market = {:ok, %{ticker: "BTCZ-24DEC2031-B80000", status: "active"}}
      exchange = {:ok, %{exchange_active: true, trading_active: true}}

      assert :ok = KalshiClient.preflight_decision(market, exchange)
    end
  end

  describe "preflight_decision/2 — market reject paths" do
    test "404 on market lookup returns :ticker_not_found" do
      market = {:error, "kalshi 404: %{\"error\" => \"market_not_found\"}"}
      exchange = {:ok, %{exchange_active: true, trading_active: true}}

      assert {:error, :ticker_not_found} =
               KalshiClient.preflight_decision(market, exchange)
    end

    test "market status=closed returns :market_closed" do
      market = {:ok, %{ticker: "BTCZ-OLD", status: "closed"}}
      exchange = {:ok, %{exchange_active: true, trading_active: true}}

      assert {:error, :market_closed} =
               KalshiClient.preflight_decision(market, exchange)
    end

    test "market status=settled returns :market_closed" do
      market = {:ok, %{ticker: "BTCZ-OLD", status: "settled"}}
      exchange = {:ok, %{exchange_active: true, trading_active: true}}

      assert {:error, :market_closed} =
               KalshiClient.preflight_decision(market, exchange)
    end

    test "market status=unopened returns :market_closed" do
      market = {:ok, %{ticker: "BTCZ-FUTURE", status: "unopened"}}
      exchange = {:ok, %{exchange_active: true, trading_active: true}}

      assert {:error, :market_closed} =
               KalshiClient.preflight_decision(market, exchange)
    end

    test "transport timeout on market probe returns :validator_unavailable (fail-closed)" do
      market = {:error, "kalshi HTTP: :timeout"}
      exchange = {:ok, %{exchange_active: true, trading_active: true}}

      assert {:error, :validator_unavailable} =
               KalshiClient.preflight_decision(market, exchange)
    end

    test "429 on market probe returns :validator_unavailable (fail-closed)" do
      market = {:error, "kalshi 429: %{\"error\" => \"rate_limited\"}"}
      exchange = {:ok, %{exchange_active: true, trading_active: true}}

      assert {:error, :validator_unavailable} =
               KalshiClient.preflight_decision(market, exchange)
    end
  end

  describe "preflight_decision/2 — exchange reject paths" do
    test "exchange_active=false returns :exchange_closed" do
      market = {:ok, %{ticker: "BTCZ-24DEC2031-B80000", status: "open"}}
      exchange = {:ok, %{exchange_active: false, trading_active: true}}

      assert {:error, :exchange_closed} =
               KalshiClient.preflight_decision(market, exchange)
    end

    test "trading_active=false returns :exchange_closed" do
      market = {:ok, %{ticker: "BTCZ-24DEC2031-B80000", status: "open"}}
      exchange = {:ok, %{exchange_active: true, trading_active: false}}

      assert {:error, :exchange_closed} =
               KalshiClient.preflight_decision(market, exchange)
    end

    test "transport timeout on exchange probe returns :validator_unavailable (fail-closed)" do
      market = {:ok, %{ticker: "BTCZ-24DEC2031-B80000", status: "open"}}
      exchange = {:error, "kalshi HTTP: :timeout"}

      assert {:error, :validator_unavailable} =
               KalshiClient.preflight_decision(market, exchange)
    end

    test "429 on exchange probe returns :validator_unavailable (fail-closed)" do
      market = {:ok, %{ticker: "BTCZ-24DEC2031-B80000", status: "open"}}
      exchange = {:error, "kalshi 429: %{\"error\" => \"rate_limited\"}"}

      assert {:error, :validator_unavailable} =
               KalshiClient.preflight_decision(market, exchange)
    end
  end

  describe "preflight_decision/2 — ordering + log hygiene" do
    test "market reject fires before exchange evaluation" do
      # If we evaluated the exchange probe first, this would surface
      # :validator_unavailable instead of :market_closed. Locking in
      # the market-first ordering so the agent-facing reason stays
      # specific to the actual fault.
      market = {:ok, %{ticker: "BTCZ-OLD", status: "closed"}}
      exchange = {:error, "kalshi HTTP: :timeout"}

      assert {:error, :market_closed} =
               KalshiClient.preflight_decision(market, exchange)
    end

    test "no error path leaks Kalshi response bodies (CyberSec ②)" do
      # All reject branches return bare atoms — `inspect/1` on any
      # of them is a 30-character atom literal, no JSON, no headers,
      # no PEM material. Asserts the surface holds across every
      # reject path the function can take.
      reject_inputs = [
        {{:error, "kalshi 404: %{secret => leaked}"}, {:ok, %{exchange_active: true, trading_active: true}}},
        {{:ok, %{status: "closed"}}, {:ok, %{exchange_active: true, trading_active: true}}},
        {{:ok, %{ticker: "X", status: "open"}}, {:ok, %{exchange_active: false, trading_active: true}}},
        {{:error, "kalshi 500: %{stack => trace}"}, {:ok, %{exchange_active: true, trading_active: true}}}
      ]

      for {m, e} <- reject_inputs do
        {:error, atom} = KalshiClient.preflight_decision(m, e)
        assert is_atom(atom)
        refute String.contains?(inspect(atom), "secret")
        refute String.contains?(inspect(atom), "stack")
        refute String.contains?(inspect(atom), "leaked")
      end
    end
  end
end
