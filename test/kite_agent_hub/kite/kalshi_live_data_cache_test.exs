defmodule KiteAgentHub.Kite.KalshiLiveDataCacheTest do
  @moduledoc """
  Locks the TTL contract on the PR-I₂ live-data cache so Phase 2
  KalshiEdgeScorer can rely on stale-read protection. Tests run
  against the running cache process from the supervision tree.
  """

  use ExUnit.Case, async: false

  alias KiteAgentHub.Kite.KalshiLiveDataCache

  setup do
    KalshiLiveDataCache.clear()
    :ok
  end

  test "put then get returns the cached value" do
    payload = %{ticker: "KXTEST-26FOO", value: 87, metadata: %{}, fetched_at: DateTime.utc_now()}

    :ok = KalshiLiveDataCache.put("KXTEST-26FOO", payload)
    assert {:ok, ^payload} = KalshiLiveDataCache.get("KXTEST-26FOO")
  end

  test "miss returns :miss for unknown ticker" do
    assert :miss = KalshiLiveDataCache.get("KXNOPE-26FOO")
  end

  test "expired entry returns :miss and gets evicted" do
    table = KalshiLiveDataCache.table_name()
    # Hand-insert a row with an already-elapsed expires_at so we
    # don't need to sleep through the real TTL. Mirrors the row
    # shape `put/2` uses.
    past = System.monotonic_time(:second) - 5
    payload = %{ticker: "KXSTALE-26", value: 1, metadata: %{}, fetched_at: DateTime.utc_now()}
    :ets.insert(table, {"KXSTALE-26", payload, past})

    assert :miss = KalshiLiveDataCache.get("KXSTALE-26")
    # second get confirms eviction happened on the first stale read
    assert :ets.lookup(table, "KXSTALE-26") == []
  end

  test "non-binary ticker returns :miss without crashing" do
    assert :miss = KalshiLiveDataCache.get(nil)
    assert :miss = KalshiLiveDataCache.get(123)
  end
end
