defmodule KiteAgentHub.Kite.RuleBasedStrategyTest do
  @moduledoc """
  Regression coverage for the rule-based exit pass.

  The original LLY incident: agent had 1 LLY share, all 1 share locked
  in a resting Alpaca sell order (held_for_orders=1, qty_available=0).
  Each tick the strategy would queue another sell, Alpaca would 403
  with "insufficient qty available", we'd write a failed TradeRecord
  row, the loop would repeat ~60s later. 30+ failed rows in 30 minutes
  before the stuck order was cancelled.

  Fix is in `to_action/2`: prefer `qty_available` over `qty` so the
  sellable size reflects what Alpaca will actually accept. When fully
  locked, `qty_available = 0` and the existing `noop_action?/1` filter
  drops the action entirely.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.Kite.RuleBasedStrategy

  defp pos(opts) do
    %{
      platform: :alpaca,
      ticker: Keyword.get(opts, :ticker, "LLY"),
      side: Keyword.get(opts, :side, "long"),
      qty: Keyword.get(opts, :qty, 1),
      qty_available: Keyword.get(opts, :qty_available, 1),
      entry_price: 800.0,
      current_price: Keyword.get(opts, :current_price, 750.0),
      pnl_pct: -6.25,
      score: Keyword.get(opts, :score, 30),
      recommendation: "exit"
    }
  end

  describe "to_action/2 — qty_available gating" do
    test "fully-locked position produces a 0-contract action that noop_action? drops" do
      action = RuleBasedStrategy.to_action(pos(qty: 1, qty_available: 0), 40)
      assert action.contracts == 0
      assert RuleBasedStrategy.noop_action?(action) == true
    end

    test "partially-locked position emits an exit for only the free shares" do
      action = RuleBasedStrategy.to_action(pos(qty: 5, qty_available: 2), 40)
      assert action.contracts == 2
      assert RuleBasedStrategy.noop_action?(action) == false
    end

    test "fully-free position emits an exit for the full qty" do
      action = RuleBasedStrategy.to_action(pos(qty: 3, qty_available: 3), 40)
      assert action.contracts == 3
    end

    test "missing qty_available falls back to qty (older score rows)" do
      p = pos(qty: 4) |> Map.delete(:qty_available)
      action = RuleBasedStrategy.to_action(p, 40)
      assert action.contracts == 4
    end

    test "noop_action? drops zero-price actions too" do
      assert RuleBasedStrategy.noop_action?(%{contracts: 1, fill_price: 0.0}) == true
      assert RuleBasedStrategy.noop_action?(%{contracts: 0, fill_price: 100.0}) == true
      assert RuleBasedStrategy.noop_action?(%{contracts: 1, fill_price: 100.0}) == false
    end
  end
end
