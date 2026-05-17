defmodule KiteAgentHub.Kite.PriceOracleCacheTest do
  @moduledoc """
  Confirms the 10s TTL cache short-circuits PriceOracle.get/1 with the
  cached payload before falling through to CoinGecko. Kept hermetic by
  pre-seeding :persistent_term so no upstream call is made.

  Companion to PriceOracleRateLimitTest — same hermetic constraint:
  any path that falls through to a real HTTP round-trip is excluded
  because CoinGecko's rate-limit state makes it CI-flaky.
  """

  use ExUnit.Case, async: false

  alias KiteAgentHub.Kite.PriceOracle

  @market "ETH-USDC"
  @cache_key {PriceOracle, :cache, @market}

  setup do
    PriceOracle.reset_rate_limit_cache()
    PriceOracle.reset_cache()

    on_exit(fn ->
      PriceOracle.reset_rate_limit_cache()
      PriceOracle.reset_cache()
    end)

    :ok
  end

  test "fresh cache entry is returned without an upstream call" do
    fixture = %{
      market: @market,
      price: "3000.00",
      price_raw: 3000.0,
      change_24h: 1.23,
      volume_24h: 1_000_000,
      trend: "bullish",
      rsi: 55
    }

    :persistent_term.put(@cache_key, {System.system_time(:second) + 10, fixture})

    assert {:ok, ^fixture} = PriceOracle.get(@market)
  end

  test "expired cache entry is ignored — rate-limit guard prevents real fetch" do
    fixture = %{
      market: @market,
      price: "0.00",
      price_raw: 0.0,
      change_24h: 0.0,
      volume_24h: 0,
      trend: "neutral",
      rsi: 50
    }

    # Past expiry timestamp — entry must be treated as stale.
    :persistent_term.put(@cache_key, {System.system_time(:second) - 1, fixture})

    # Activate rate-limit cooldown so the stale-cache miss short-circuits
    # before any HTTP attempt, keeping the test hermetic.
    :persistent_term.put({PriceOracle, :rate_limited_until}, System.system_time(:second) + 60)

    assert {:error, :rate_limited} = PriceOracle.get(@market)
  end

  test "reset_cache/0 erases all known-market entries" do
    fixture = %{market: @market, price: "0.00"}
    :persistent_term.put(@cache_key, {System.system_time(:second) + 10, fixture})

    assert :persistent_term.get(@cache_key, :missing) != :missing

    PriceOracle.reset_cache()

    assert :persistent_term.get(@cache_key, :missing) == :missing
  end
end
