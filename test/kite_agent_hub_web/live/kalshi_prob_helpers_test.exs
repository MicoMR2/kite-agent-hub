defmodule KiteAgentHubWeb.KalshiProbHelpersTest do
  @moduledoc """
  PR-J.5 helper coverage for the implied-prob bar in the new
  Open Positions card grid.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHubWeb.DashboardLive

  describe "kalshi_implied_prob_pct/1" do
    test "0.5 current_price → 50" do
      assert 50 = DashboardLive.kalshi_implied_prob_pct(%{current_price: 0.5})
    end

    test "0.87 → 87 (truncated)" do
      assert 87 = DashboardLive.kalshi_implied_prob_pct(%{current_price: 0.87})
    end

    test "0.0 → 0" do
      assert 0 = DashboardLive.kalshi_implied_prob_pct(%{current_price: 0.0})
    end

    test "1.0 → 100" do
      assert 100 = DashboardLive.kalshi_implied_prob_pct(%{current_price: 1.0})
    end

    test "clamps negative input to 0" do
      assert 0 = DashboardLive.kalshi_implied_prob_pct(%{current_price: -0.5})
    end

    test "clamps over-1 input to 100" do
      assert 100 = DashboardLive.kalshi_implied_prob_pct(%{current_price: 1.5})
    end

    test "missing/non-number → 0 default" do
      assert 0 = DashboardLive.kalshi_implied_prob_pct(%{})
      assert 0 = DashboardLive.kalshi_implied_prob_pct(%{current_price: nil})
      assert 0 = DashboardLive.kalshi_implied_prob_pct(%{current_price: "bad"})
    end
  end

  describe "kalshi_side_prob_pct/2" do
    test "yes side uses raw prob" do
      assert 75 = DashboardLive.kalshi_side_prob_pct(%{side: "yes"}, 75)
    end

    test "no side inverts (100 - yes)" do
      assert 25 = DashboardLive.kalshi_side_prob_pct(%{side: "no"}, 75)
    end

    test "edges (0 and 100) invert correctly" do
      assert 100 = DashboardLive.kalshi_side_prob_pct(%{side: "no"}, 0)
      assert 0 = DashboardLive.kalshi_side_prob_pct(%{side: "no"}, 100)
    end

    test "unrecognized side defaults to yes-style read" do
      assert 75 = DashboardLive.kalshi_side_prob_pct(%{side: nil}, 75)
      assert 75 = DashboardLive.kalshi_side_prob_pct(%{side: "weird"}, 75)
    end
  end
end
