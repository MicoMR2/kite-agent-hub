defmodule KiteAgentHub.Kite.PriceOracleRateLimitTest do
  @moduledoc """
  Confirms the 60s rate-limit cooldown short-circuits subsequent
  PriceOracle.get/1 calls without an HTTP round-trip. The cooldown
  is stored in :persistent_term so it's process-global; the tests
  reset it between runs.
  """

  use ExUnit.Case, async: false

  alias KiteAgentHub.Kite.PriceOracle

  setup do
    PriceOracle.reset_rate_limit_cache()
    on_exit(&PriceOracle.reset_rate_limit_cache/0)
    :ok
  end

  test "no cooldown set → call attempts the HTTP fetch" do
    # No cooldown active. The function will hit the network; we don't
    # care about success/failure here, only that it does not return
    # the cached `:rate_limited` short-circuit shape.
    refute_raise = fn ->
      result = PriceOracle.get("ETH-USDC")

      case result do
        {:ok, %{}} -> :ok
        {:error, :rate_limited} -> flunk("Expected the call to attempt HTTP, got cached :rate_limited")
        {:error, _other} -> :ok
      end
    end

    refute_raise.()
  end

  test "after a recorded 429, subsequent calls short-circuit with :rate_limited" do
    :persistent_term.put({PriceOracle, :rate_limited_until}, System.system_time(:second) + 60)

    assert {:error, :rate_limited} = PriceOracle.get("ETH-USDC")
    assert {:error, :rate_limited} = PriceOracle.get("BTC-USDC")
  end

  test "cooldown clears after the until-timestamp passes" do
    # Set the cooldown to one second in the past — the next call
    # should NOT short-circuit.
    :persistent_term.put({PriceOracle, :rate_limited_until}, System.system_time(:second) - 1)

    case PriceOracle.get("ETH-USDC") do
      {:error, :rate_limited} -> flunk("Expected expired cooldown to allow a fresh fetch")
      _ -> :ok
    end
  end
end
