defmodule KiteAgentHub.Kite.PriceOracleRateLimitTest do
  @moduledoc """
  Confirms the 60s rate-limit cooldown short-circuits subsequent
  PriceOracle.get/1 calls without an HTTP round-trip. We test only
  the cooldown-active path here so the suite stays hermetic — the
  no-cooldown / expired-cooldown paths fall through to a real
  CoinGecko round-trip whose result depends on rate-limit state on
  the public API and is too flaky for CI. The cache logic itself
  is a single :persistent_term lookup; the no-cooldown path is
  exercised every time agent_runner ticks in dev/prod.
  """

  use ExUnit.Case, async: false

  alias KiteAgentHub.Kite.PriceOracle

  setup do
    PriceOracle.reset_rate_limit_cache()
    on_exit(&PriceOracle.reset_rate_limit_cache/0)
    :ok
  end

  test "after a recorded 429, subsequent calls short-circuit with :rate_limited" do
    :persistent_term.put({PriceOracle, :rate_limited_until}, System.system_time(:second) + 60)

    assert {:error, :rate_limited} = PriceOracle.get("ETH-USDC")
    assert {:error, :rate_limited} = PriceOracle.get("BTC-USDC")
  end

  test "reset_rate_limit_cache/0 clears the persisted timestamp" do
    :persistent_term.put({PriceOracle, :rate_limited_until}, System.system_time(:second) + 60)
    assert {:error, :rate_limited} = PriceOracle.get("ETH-USDC")

    PriceOracle.reset_rate_limit_cache()
    # Cache cleared — guard returns false even before any new HTTP attempt.
    assert :persistent_term.get({PriceOracle, :rate_limited_until}, :missing) == :missing
  end
end
