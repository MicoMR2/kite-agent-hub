defmodule KiteAgentHub.Kite.KalshiMarketScorerTest do
  use ExUnit.Case, async: true

  alias KiteAgentHub.Kite.KalshiMarketScorer

  # Pinned "now" so time-proximity assertions are deterministic.
  @now ~U[2026-04-16 18:00:00Z]

  defp iso_from_now(seconds) do
    @now |> DateTime.add(seconds, :second) |> DateTime.to_iso8601()
  end

  defp market(attrs) do
    Map.merge(
      %{
        "ticker" => "KX-TEST",
        "status" => "open",
        "volume_24h" => 500,
        "yes_bid" => 50,
        "yes_ask" => 55,
        # Default ~12h to close so time_score is live (~95).
        "close_time" => iso_from_now(12 * 3600)
      },
      attrs
    )
  end

  describe "score_market/2" do
    test "liquid + short-dated + tight spread produces a high score tagged tradability" do
      m =
        market(%{
          "volume_24h" => 800,
          "yes_bid" => 52,
          "yes_ask" => 54,
          "close_time" => iso_from_now(6 * 3600)
        })

      row = KalshiMarketScorer.score_market(m, @now)

      assert row.score > 80
      assert row.score_type == "tradability"
      assert row.spread_cents == 2
      assert row.days_to_close < 1
      assert row.breakdown.liquidity > 0
      assert row.breakdown.time > 90
    end

    test "hard-zero when status is not open (both halves)" do
      row = KalshiMarketScorer.score_market(market(%{"status" => "closed"}), @now)
      assert row.score == 0
      assert row.breakdown.liquidity == 0
      assert row.breakdown.time == 0
    end

    test "hard-zero liquidity when volume under floor (time still contributes)" do
      m = market(%{"volume_24h" => 5, "close_time" => iso_from_now(6 * 3600)})
      row = KalshiMarketScorer.score_market(m, @now)

      assert row.breakdown.liquidity == 0
      assert row.breakdown.time > 90
      # 50/50 weight, so only time contributes; final ≈ 48
      assert row.score > 40 and row.score < 60
    end

    test "hard-zero liquidity when spread exceeds max" do
      m = market(%{"yes_bid" => 20, "yes_ask" => 80})
      row = KalshiMarketScorer.score_market(m, @now)
      assert row.breakdown.liquidity == 0
      assert row.spread_cents == 60
    end

    test "time_score is 0 when close_time is missing or in the past" do
      past = KalshiMarketScorer.score_market(market(%{"close_time" => iso_from_now(-3600)}), @now)
      missing = KalshiMarketScorer.score_market(market(%{"close_time" => nil}), @now)

      assert past.breakdown.time == 0
      assert missing.breakdown.time == 0
    end

    test "time_score decays at 5 points per day, clamped to zero at 20+ days" do
      near = KalshiMarketScorer.score_market(market(%{"close_time" => iso_from_now(1 * 86_400)}), @now)
      mid = KalshiMarketScorer.score_market(market(%{"close_time" => iso_from_now(5 * 86_400)}), @now)
      far = KalshiMarketScorer.score_market(market(%{"close_time" => iso_from_now(30 * 86_400)}), @now)

      assert near.breakdown.time == 95
      assert mid.breakdown.time == 75
      assert far.breakdown.time == 0
    end

    test "parses numeric strings for volume/bid/ask" do
      m = market(%{"volume_24h" => "400", "yes_bid" => "48", "yes_ask" => "50"})
      row = KalshiMarketScorer.score_market(m, @now)

      assert row.volume_24h == 400.0
      assert row.spread_cents == 2.0
      assert row.score > 0
    end

    test "falls back to `volume` when `volume_24h` is absent" do
      m = market(%{"volume_24h" => nil, "volume" => 300})
      row = KalshiMarketScorer.score_market(m, @now)
      assert row.volume_24h == 300
      assert row.breakdown.liquidity > 0
    end
  end

  describe "score_markets/2" do
    test "filters by min_score and sorts desc" do
      markets = [
        market(%{"ticker" => "A", "volume_24h" => 50, "yes_bid" => 30, "yes_ask" => 50,
                 "close_time" => iso_from_now(30 * 86_400)}),
        market(%{"ticker" => "B", "volume_24h" => 800, "yes_bid" => 52, "yes_ask" => 54,
                 "close_time" => iso_from_now(6 * 3600)}),
        market(%{"ticker" => "C", "volume_24h" => 400, "yes_bid" => 49, "yes_ask" => 51,
                 "close_time" => iso_from_now(3 * 86_400)})
      ]

      rows = KalshiMarketScorer.score_markets(markets, 50)
      tickers = Enum.map(rows, & &1.ticker)

      assert "A" not in tickers
      # B (short-dated liquid) should outrank C (mid-dated).
      assert hd(rows).ticker == "B"
      assert Enum.all?(rows, &(&1.score_type == "tradability"))
    end

    test "empty list returns empty list" do
      assert KalshiMarketScorer.score_markets([]) == []
    end
  end
end
