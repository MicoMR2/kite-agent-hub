defmodule KiteAgentHub.TradingPlatforms.KalshiPositionKeysTest do
  @moduledoc """
  PR-J.8 regression lock: Kalshi position parsing must defensively
  try multiple key names for quantity / avg price / last price.
  Pre-fix the dashboard rendered `0qty 0price` when Kalshi returned
  positions under non-"position" / non-"average_price" keys (Mico
  10855).
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.TradingPlatforms.KalshiClient

  describe "parse_position_qty/1" do
    test "reads canonical `position` key" do
      assert 5 = KalshiClient.parse_position_qty(%{"position" => 5})
    end

    test "falls back to `quantity` when position is missing" do
      assert 7 = KalshiClient.parse_position_qty(%{"quantity" => 7})
    end

    test "falls back to `count`" do
      assert 3 = KalshiClient.parse_position_qty(%{"count" => 3})
    end

    test "falls back to `size`" do
      assert 2 = KalshiClient.parse_position_qty(%{"size" => 2})
    end

    test "falls back to `contracts`" do
      assert 9 = KalshiClient.parse_position_qty(%{"contracts" => 9})
    end

    test "prefers position over fallbacks" do
      assert 5 = KalshiClient.parse_position_qty(%{"position" => 5, "quantity" => 99})
    end

    test "coerces float to integer" do
      assert 4 = KalshiClient.parse_position_qty(%{"position" => 4.7})
    end

    test "parses string integers" do
      assert 6 = KalshiClient.parse_position_qty(%{"position" => "6"})
    end

    test "defaults to 0 on missing + non-map input" do
      assert 0 = KalshiClient.parse_position_qty(%{})
      assert 0 = KalshiClient.parse_position_qty(nil)
      assert 0 = KalshiClient.parse_position_qty("garbage")
    end
  end

  describe "parse_position_avg_cents/1" do
    test "reads canonical `average_price`" do
      assert 75 = KalshiClient.parse_position_avg_cents(%{"average_price" => 75})
    end

    test "falls back to `avg_price`" do
      assert 50 = KalshiClient.parse_position_avg_cents(%{"avg_price" => 50})
    end

    test "falls back to `entry_price`" do
      assert 65 = KalshiClient.parse_position_avg_cents(%{"entry_price" => 65})
    end

    test "falls back to `price`" do
      assert 40 = KalshiClient.parse_position_avg_cents(%{"price" => 40})
    end

    test "falls back to `fill_price`" do
      assert 30 = KalshiClient.parse_position_avg_cents(%{"fill_price" => 30})
    end

    test "defaults to 0 on missing + non-map" do
      assert 0 = KalshiClient.parse_position_avg_cents(%{})
      assert 0 = KalshiClient.parse_position_avg_cents(nil)
    end
  end

  describe "parse_position_last_cents/1" do
    test "reads canonical `last_price`" do
      assert 80 = KalshiClient.parse_position_last_cents(%{"last_price" => 80})
    end

    test "falls back to `current_price` / `mark_price`" do
      assert 55 = KalshiClient.parse_position_last_cents(%{"current_price" => 55})
      assert 33 = KalshiClient.parse_position_last_cents(%{"mark_price" => 33})
    end

    test "defaults to 0 on missing" do
      assert 0 = KalshiClient.parse_position_last_cents(%{})
    end
  end
end
