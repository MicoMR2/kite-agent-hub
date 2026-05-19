defmodule KiteAgentHubWeb.KalshiSparklineHelpersTest do
  @moduledoc """
  Pure-helper coverage for PR-J.7: gradient polygon construction +
  path-length estimation used by the SparklineMount JS hook.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHubWeb.DashboardLive

  describe "kalshi_sparkline_polygon_points/3" do
    test "closes the polyline back to the baseline" do
      assert "0,20 0,10 30,5 60,0 64,20" =
               DashboardLive.kalshi_sparkline_polygon_points("0,10 30,5 60,0", 64, 20)
    end

    test "empty / whitespace input returns empty string" do
      assert "" = DashboardLive.kalshi_sparkline_polygon_points("", 64, 20)
      assert "" = DashboardLive.kalshi_sparkline_polygon_points("   ", 64, 20)
    end

    test "non-binary input returns empty string (defensive)" do
      assert "" = DashboardLive.kalshi_sparkline_polygon_points(nil, 64, 20)
      assert "" = DashboardLive.kalshi_sparkline_polygon_points(:atom, 64, 20)
    end
  end

  describe "kalshi_sparkline_path_length/3" do
    test "returns the sum of segment euclidean distances" do
      data = [%{v: 0.0}, %{v: 1.0}, %{v: 0.0}]
      len = DashboardLive.kalshi_sparkline_path_length(data, 100, 100)
      assert len > 0
      assert is_float(len)
    end

    test "single-point input returns 0 (no segments to draw)" do
      assert 0.0 = DashboardLive.kalshi_sparkline_path_length([%{v: 1.0}], 100, 100)
    end

    test "empty input returns 0" do
      assert 0.0 = DashboardLive.kalshi_sparkline_path_length([], 100, 100)
    end

    test "constant values produce a horizontal line of width-length" do
      data = [%{v: 50.0}, %{v: 50.0}, %{v: 50.0}, %{v: 50.0}]
      len = DashboardLive.kalshi_sparkline_path_length(data, 80, 22)
      # With identical values + 4 points, the line is flat at the
      # bottom of the band — segment length sums to the width.
      assert_in_delta len, 80.0, 1.0
    end
  end
end
