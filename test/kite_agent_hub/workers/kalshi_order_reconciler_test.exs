defmodule KiteAgentHub.Workers.KalshiOrderReconcilerTest do
  @moduledoc """
  Hermetic coverage for the reconciler's pure decision logic
  (`lookup_strategy/1` + `reconcile_action/2`). The side-effecting
  parts (`perform/1`, `fetch_kalshi_orders/2`) hit Kalshi + Repo and
  are integration-tested separately.

  Pinning the three constraints CyberSec required (msg 10649 + 10651):

    * Legacy zombies (NULL on both ids) → LOG ONLY, no DB mutation
    * Hard-ID matches (platform_order_id) → safe to settle/cancel
    * Idempotency matches (client_order_id) → safe + back-fill the
      missing platform_order_id
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.Trading.TradeRecord
  alias KiteAgentHub.Workers.KalshiOrderReconciler

  describe "lookup_strategy/1" do
    test ":by_order_id when platform_order_id is set" do
      trade = %TradeRecord{platform_order_id: "abc-123", client_order_id: nil}
      assert :by_order_id = KalshiOrderReconciler.lookup_strategy(trade)
    end

    test ":by_order_id takes priority when both IDs are set" do
      # platform_order_id is the strongest signal — Kalshi gave us the
      # actual ID so we shouldn't fall back to the dedup-key lookup.
      trade = %TradeRecord{platform_order_id: "abc-123", client_order_id: "uuid-x"}
      assert :by_order_id = KalshiOrderReconciler.lookup_strategy(trade)
    end

    test ":by_client_id when only client_order_id is set" do
      trade = %TradeRecord{platform_order_id: nil, client_order_id: "uuid-x"}
      assert :by_client_id = KalshiOrderReconciler.lookup_strategy(trade)
    end

    test ":legacy_zombie when both are nil" do
      trade = %TradeRecord{platform_order_id: nil, client_order_id: nil}
      assert :legacy_zombie = KalshiOrderReconciler.lookup_strategy(trade)
    end

    test ":legacy_zombie when both are empty strings (defensive)" do
      trade = %TradeRecord{platform_order_id: "", client_order_id: ""}
      assert :legacy_zombie = KalshiOrderReconciler.lookup_strategy(trade)
    end
  end

  describe "reconcile_action/2" do
    test "empty upstream → :no_change" do
      trade = %TradeRecord{platform_order_id: "abc", status: "open"}
      assert {:no_change, :empty_response} = KalshiOrderReconciler.reconcile_action(trade, [])
    end

    test "executed → :settle with status: settled" do
      trade = %TradeRecord{platform_order_id: "abc", status: "open"}
      order = %{status: "executed", order_id: "abc"}
      assert {:settle, %{status: "settled"}} = KalshiOrderReconciler.reconcile_action(trade, [order])
    end

    test "filled → :settle" do
      trade = %TradeRecord{platform_order_id: "abc", status: "open"}
      order = %{status: "filled", order_id: "abc"}
      assert {:settle, %{status: "settled"}} = KalshiOrderReconciler.reconcile_action(trade, [order])
    end

    test "cancelled (US spelling) → :cancel" do
      trade = %TradeRecord{platform_order_id: "abc", status: "open"}
      order = %{status: "canceled", order_id: "abc"}
      assert {:cancel, %{status: "cancelled"}} = KalshiOrderReconciler.reconcile_action(trade, [order])
    end

    test "cancelled (UK spelling) → :cancel" do
      trade = %TradeRecord{platform_order_id: "abc", status: "open"}
      order = %{status: "cancelled", order_id: "abc"}
      assert {:cancel, %{status: "cancelled"}} = KalshiOrderReconciler.reconcile_action(trade, [order])
    end

    test "expired → :cancel" do
      trade = %TradeRecord{platform_order_id: "abc", status: "open"}
      order = %{status: "expired", order_id: "abc"}
      assert {:cancel, %{status: "cancelled"}} = KalshiOrderReconciler.reconcile_action(trade, [order])
    end

    test "resting → :no_change (still on book)" do
      trade = %TradeRecord{platform_order_id: "abc", status: "open"}
      order = %{status: "resting", order_id: "abc"}
      assert :no_change = KalshiOrderReconciler.reconcile_action(trade, [order])
    end

    test "by_client_id recovery: resting + no platform_order_id → :backfill" do
      # Write-ordering recovery path: we POSTed, Req timed out before
      # storing platform_order_id, the reconciler found the order via
      # client_order_id, and now back-fills the missing ID so the next
      # sweep can use :by_order_id (the stronger path).
      trade = %TradeRecord{platform_order_id: nil, client_order_id: "uuid-x", status: "open"}
      order = %{status: "resting", order_id: "discovered-id"}

      assert {:backfill, %{platform_order_id: "discovered-id"}} =
               KalshiOrderReconciler.reconcile_action(trade, [order])
    end

    test "settle also back-fills platform_order_id when missing" do
      trade = %TradeRecord{platform_order_id: nil, client_order_id: "uuid-x", status: "open"}
      order = %{status: "executed", order_id: "discovered-id"}

      assert {:settle, attrs} = KalshiOrderReconciler.reconcile_action(trade, [order])
      assert attrs.status == "settled"
      assert attrs.platform_order_id == "discovered-id"
    end

    test "unknown status → :no_change (don't speculate)" do
      trade = %TradeRecord{platform_order_id: "abc", status: "open"}
      order = %{status: "weird_new_status", order_id: "abc"}
      assert :no_change = KalshiOrderReconciler.reconcile_action(trade, [order])
    end

    test "missing :status field → :no_change" do
      trade = %TradeRecord{platform_order_id: "abc", status: "open"}
      order = %{order_id: "abc"}
      assert :no_change = KalshiOrderReconciler.reconcile_action(trade, [order])
    end

    test "settle does not overwrite an already-set platform_order_id" do
      trade = %TradeRecord{platform_order_id: "existing", client_order_id: "uuid-x"}
      order = %{status: "executed", order_id: "different-id"}

      assert {:settle, attrs} = KalshiOrderReconciler.reconcile_action(trade, [order])
      refute Map.has_key?(attrs, :platform_order_id)
    end
  end
end
