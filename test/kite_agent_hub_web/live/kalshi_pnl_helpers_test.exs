defmodule KiteAgentHubWeb.KalshiPnlHelpersTest do
  @moduledoc """
  Pure-helper coverage for PR-J.6 P&L graph parity. Endpoint coord
  for the last-value chip + path length for the SparklineMount
  draw-in + date label strings + y-axis peak label.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHubWeb.DashboardLive

  defp settle(time, revenue, fees \\ 0.0) do
    %{settled_time: time, revenue: revenue, fees: fees}
  end

  describe "kalshi_pnl_endpoint/3" do
    test "returns endpoint coords + final value" do
      settlements = [
        settle("2026-05-01T00:00:00Z", 10.0),
        settle("2026-05-02T00:00:00Z", -3.0),
        settle("2026-05-03T00:00:00Z", 5.0)
      ]

      assert %{x: 640.0, y: y, value: 12.0} =
               DashboardLive.kalshi_pnl_endpoint(settlements, 640, 200)

      assert is_float(y)
    end

    test "single-settlement input returns nil (no segments)" do
      assert nil == DashboardLive.kalshi_pnl_endpoint([settle("2026-05-01T00:00:00Z", 1.0)], 640, 200)
    end

    test "empty input returns nil" do
      assert nil == DashboardLive.kalshi_pnl_endpoint([], 640, 200)
    end
  end

  describe "kalshi_pnl_path_length/3" do
    test "sums segment euclidean distances" do
      settlements = [
        settle("2026-05-01T00:00:00Z", 5.0),
        settle("2026-05-02T00:00:00Z", -2.0),
        settle("2026-05-03T00:00:00Z", 7.0)
      ]

      len = DashboardLive.kalshi_pnl_path_length(settlements, 640, 200)
      assert is_float(len)
      assert len > 0
    end

    test "empty input returns 0.0" do
      assert 0.0 = DashboardLive.kalshi_pnl_path_length([], 640, 200)
    end

    test "single-settlement returns 0 (no segments to measure)" do
      assert 0.0 = DashboardLive.kalshi_pnl_path_length([settle("2026-05-01T00:00:00Z", 1.0)], 640, 200)
    end
  end

  describe "kalshi_pnl_dates/1" do
    test "returns earliest + latest as YYYY-MM-DD" do
      settlements = [
        settle("2026-05-03T12:00:00Z", 1.0),
        settle("2026-05-01T00:00:00Z", 1.0),
        settle("2026-05-02T08:00:00Z", 1.0)
      ]

      assert {"2026-05-01", "2026-05-03"} = DashboardLive.kalshi_pnl_dates(settlements)
    end

    test "handles nil settled_time by skipping (no crash)" do
      settlements = [
        settle("2026-05-01T00:00:00Z", 1.0),
        settle(nil, 1.0),
        settle("2026-05-02T00:00:00Z", 1.0)
      ]

      assert {"2026-05-01", "2026-05-02"} = DashboardLive.kalshi_pnl_dates(settlements)
    end

    test "empty returns em-dashes" do
      assert {"—", "—"} = DashboardLive.kalshi_pnl_dates([])
    end

    test "single settlement returns em-dashes (not chartable)" do
      assert {"—", "—"} =
               DashboardLive.kalshi_pnl_dates([settle("2026-05-01T00:00:00Z", 1.0)])
    end
  end

  describe "kalshi_pnl_max_label/1" do
    test "returns the peak absolute cumulative value as $N.NN" do
      settlements = [
        settle("2026-05-01T00:00:00Z", 5.0),
        settle("2026-05-02T00:00:00Z", -8.0),
        settle("2026-05-03T00:00:00Z", 2.0)
      ]

      # Cumulative: 5, -3, -1 → peak abs = 5
      assert "$5.00" = DashboardLive.kalshi_pnl_max_label(settlements)
    end

    test "deep negative session reports its trough" do
      settlements = [
        settle("2026-05-01T00:00:00Z", -10.0),
        settle("2026-05-02T00:00:00Z", -5.0)
      ]

      # Cumulative: -10, -15 → peak abs = 15
      assert "$15.00" = DashboardLive.kalshi_pnl_max_label(settlements)
    end

    test "empty returns $0" do
      assert "$0" = DashboardLive.kalshi_pnl_max_label([])
    end
  end
end
