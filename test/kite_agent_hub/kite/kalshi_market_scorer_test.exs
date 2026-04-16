defmodule KiteAgentHub.Kite.KalshiMarketScorerTest do
  use ExUnit.Case, async: true

  alias KiteAgentHub.Kite.KalshiMarketScorer

  defp market(attrs) do
    Map.merge(
      %{
        "ticker" => "KX-TEST",
        "status" => "open",
        "volume_24h" => 500,
        "yes_bid" => 50,
        "yes_ask" => 55
      },
      attrs
    )
  end

  describe "score_market/1" do
    test "scores a liquid, tight-spread open market above 50" do
      m = market(%{"volume_24h" => 800, "yes_bid" => 52, "yes_ask" => 54})
      row = KalshiMarketScorer.score_market(m)

      assert row.score > 50
      assert row.spread_cents == 2
      assert row.volume_24h == 800
    end

    test "hard-zero when status is not open" do
      row = KalshiMarketScorer.score_market(market(%{"status" => "closed"}))
      assert row.score == 0
    end

    test "hard-zero when volume_24h is under the floor" do
      row = KalshiMarketScorer.score_market(market(%{"volume_24h" => 5}))
      assert row.score == 0
    end

    test "hard-zero when spread exceeds the max" do
      row = KalshiMarketScorer.score_market(market(%{"yes_bid" => 20, "yes_ask" => 80}))
      assert row.score == 0
      assert row.spread_cents == 60
    end

    test "hard-zero when bid or ask is missing" do
      row = KalshiMarketScorer.score_market(market(%{"yes_bid" => nil}))
      assert row.score == 0
    end

    test "parses numeric strings for volume/bid/ask" do
      m = market(%{"volume_24h" => "400", "yes_bid" => "48", "yes_ask" => "50"})
      row = KalshiMarketScorer.score_market(m)
      assert row.score > 0
      assert row.volume_24h == 400.0
      assert row.spread_cents == 2.0
    end

    test "falls back to `volume` when `volume_24h` is absent" do
      m = market(%{"volume_24h" => nil, "volume" => 300})
      row = KalshiMarketScorer.score_market(m)
      assert row.volume_24h == 300
      assert row.score > 0
    end

    test "saturates volume component at 1000" do
      tighter =
        KalshiMarketScorer.score_market(
          market(%{"volume_24h" => 999, "yes_bid" => 52, "yes_ask" => 53})
        )

      saturated =
        KalshiMarketScorer.score_market(
          market(%{"volume_24h" => 100_000, "yes_bid" => 52, "yes_ask" => 53})
        )

      # Both should be very close since volume saturates at 1000; spread
      # dominates the difference (same here), so the two scores should
      # be within 1 point of each other.
      assert abs(saturated.score - tighter.score) <= 1
    end
  end

  describe "score_markets/2" do
    test "filters by min_score and sorts desc" do
      markets = [
        market(%{"ticker" => "A", "volume_24h" => 50, "yes_bid" => 30, "yes_ask" => 50}),
        market(%{"ticker" => "B", "volume_24h" => 800, "yes_bid" => 52, "yes_ask" => 54}),
        market(%{"ticker" => "C", "volume_24h" => 400, "yes_bid" => 49, "yes_ask" => 51})
      ]

      rows = KalshiMarketScorer.score_markets(markets, 50)

      # A is filtered (low score). B and C remain, desc by score.
      assert Enum.map(rows, & &1.ticker) == ["B", "C"]
      assert hd(rows).score >= 50
    end

    test "empty list returns empty list" do
      assert KalshiMarketScorer.score_markets([]) == []
    end
  end
end
