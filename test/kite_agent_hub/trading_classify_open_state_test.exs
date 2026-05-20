defmodule KiteAgentHub.TradingClassifyOpenStateTest do
  @moduledoc """
  Pure-helper coverage for PR-J.3 chip-state classification. The
  3-state matrix maps directly to the reconciler's lookup_strategy
  from PR-B: platform_order_id wins, then client_order_id, then
  legacy_zombie.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.Trading

  test "platform_order_id set → :by_order_id" do
    assert :by_order_id = Trading.classify_open_state("abc-123", nil)
    assert :by_order_id = Trading.classify_open_state("abc-123", "uuid-x")
  end

  test "client_order_id only → :by_client_id (recovery in flight)" do
    assert :by_client_id = Trading.classify_open_state(nil, "uuid-x")
  end

  test "both nil → :legacy_zombie" do
    assert :legacy_zombie = Trading.classify_open_state(nil, nil)
  end

  test "empty strings on both → :legacy_zombie (defensive)" do
    assert :legacy_zombie = Trading.classify_open_state("", "")
  end

  test "platform_order_id empty string falls back to client_order_id" do
    assert :by_client_id = Trading.classify_open_state("", "uuid-x")
  end

  test "client_order_id empty string with nil platform → :legacy_zombie" do
    assert :legacy_zombie = Trading.classify_open_state(nil, "")
  end
end
