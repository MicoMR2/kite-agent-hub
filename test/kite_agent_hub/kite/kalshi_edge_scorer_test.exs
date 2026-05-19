defmodule KiteAgentHub.Kite.KalshiEdgeScorerTest do
  @moduledoc """
  Locks the PR-K1 + PR-K2 scoring contract for KalshiEdgeScorer
  (Phorari 10747 signals 1 + 2 — time-decay / closeout edge + order-
  book imbalance). Pure math, no HTTP, no DB; runs async.

  Post-K2 rebalance: time_decay caps at 50 pts, book_imbalance caps
  at 50 pts. Total score = sum, clamped to 100. K1 tests below
  use the new 50-pt time_decay ceiling.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.Kite.KalshiEdgeScorer

  defp now, do: DateTime.from_naive!(~N[2026-05-19 18:00:00.000000], "Etc/UTC")
  defp in_hours(h), do: DateTime.add(now(), trunc(h * 3600), :second) |> DateTime.to_iso8601()

  describe "score_market/2 — time_decay alone (no book data)" do
    test "95% yes one hour before close → time_decay near 45" do
      market = %{
        ticker: "KXTEST-26FOO",
        status: "open",
        yes_bid: 94,
        yes_ask: 96,
        close_time: in_hours(1)
      }

      row = KalshiEdgeScorer.score_market(market, now())

      assert row.breakdown.time_decay in 40..50
      assert row.breakdown.book_imbalance == 0
      assert row.score == row.breakdown.time_decay
      assert row.implied_prob == 0.95
      assert_in_delta row.hours_to_close, 1.0, 0.01
    end

    test "95% no one hour before close → symmetric time_decay" do
      market = %{
        ticker: "KXTEST-26FOO",
        status: "open",
        yes_bid: 4,
        yes_ask: 6,
        close_time: in_hours(1)
      }

      row = KalshiEdgeScorer.score_market(market, now())
      assert row.breakdown.time_decay in 40..50
    end

    test "75% yes 6 hours before close → time_decay near 19" do
      market = %{
        ticker: "KXTEST-26FOO",
        status: "open",
        yes_bid: 74,
        yes_ask: 76,
        close_time: in_hours(6)
      }

      row = KalshiEdgeScorer.score_market(market, now())
      assert row.breakdown.time_decay in 15..25
    end
  end

  describe "score_market/2 — hard zeros" do
    test "market not open → score 0 + :pass" do
      for status <- ["closed", "settled", "unopened", "finalized", nil] do
        market = %{
          ticker: "KXTEST-26FOO",
          status: status,
          yes_bid: 94,
          yes_ask: 96,
          yes_levels: [[50, 1000]],
          no_levels: [[50, 10]],
          volume_24h: 5000,
          close_time: in_hours(1)
        }

        row = KalshiEdgeScorer.score_market(market, now())
        assert row.score == 0, "expected 0 for status=#{inspect(status)}, got #{row.score}"
        assert row.recommendation == :pass
        assert row.breakdown.book_imbalance == 0
      end
    end

    test "close_time past → score 0" do
      market = %{
        ticker: "KXTEST-26FOO",
        status: "open",
        yes_bid: 94,
        yes_ask: 96,
        close_time: in_hours(-1)
      }

      assert KalshiEdgeScorer.score_market(market, now()).score == 0
    end

    test "missing bid/ask + missing last_price → score 0" do
      market = %{ticker: "KXTEST-26FOO", status: "open", close_time: in_hours(1)}
      row = KalshiEdgeScorer.score_market(market, now())
      assert row.score == 0
      assert row.implied_prob == nil
    end

    test "50% yes → score 0 regardless of urgency" do
      market = %{
        ticker: "KXTEST-26FOO",
        status: "open",
        yes_bid: 49,
        yes_ask: 51,
        close_time: in_hours(0.1)
      }

      assert KalshiEdgeScorer.score_market(market, now()).score == 0
    end

    test "95% yes one week before close → score 0" do
      market = %{
        ticker: "KXTEST-26FOO",
        status: "open",
        yes_bid: 94,
        yes_ask: 96,
        close_time: in_hours(168)
      }

      row = KalshiEdgeScorer.score_market(market, now())
      assert row.breakdown.time_decay == 0
    end
  end

  describe "score_market/2 — defensive parsing" do
    test "string-keyed map (parse_market is bypassed) still works" do
      market = %{
        "ticker" => "KXTEST-26FOO",
        "status" => "open",
        "yes_bid" => 94,
        "yes_ask" => 96,
        "close_time" => in_hours(1)
      }

      row = KalshiEdgeScorer.score_market(market, now())
      assert row.breakdown.time_decay in 40..50
    end

    test "fallback to last_price when bid/ask are missing" do
      market = %{
        ticker: "KXTEST-26FOO",
        status: "open",
        last_price_cents: 95,
        close_time: in_hours(1)
      }

      row = KalshiEdgeScorer.score_market(market, now())
      assert row.implied_prob == 0.95
      assert row.breakdown.time_decay in 40..50
    end
  end

  describe "compute_time_decay/2 — pure math" do
    test "returns {pts, score} tuple with pts equal to score" do
      {pts, score} = KalshiEdgeScorer.compute_time_decay(0.95, 1.0)
      assert pts == score
    end

    test "non-numeric inputs return {0, 0}" do
      assert {0, 0} = KalshiEdgeScorer.compute_time_decay(nil, 1.0)
      assert {0, 0} = KalshiEdgeScorer.compute_time_decay(0.95, nil)
      assert {0, 0} = KalshiEdgeScorer.compute_time_decay(0.95, -1)
    end

    test "clamps to 0-50 range post-K2 rebalance" do
      {_pts, score} = KalshiEdgeScorer.compute_time_decay(1.0, 0.001)
      assert score in 0..50
    end
  end

  describe "compute_book_imbalance/3 — pure math (PR-K2)" do
    test "equal depth → 0 pts (no signal)" do
      assert 0 = KalshiEdgeScorer.compute_book_imbalance([[50, 100]], [[50, 100]], 5000)
    end

    test "10x yes vs no depth + 1000+ volume → saturates near 50 pts" do
      pts = KalshiEdgeScorer.compute_book_imbalance([[50, 1000]], [[50, 100]], 5000)
      assert pts in 45..50
    end

    test "100x imbalance still caps at 50 pts (saturation)" do
      pts = KalshiEdgeScorer.compute_book_imbalance([[50, 10_000]], [[50, 100]], 5000)
      assert pts == 50
    end

    test "symmetric — 10x no vs yes depth scores the same" do
      pts = KalshiEdgeScorer.compute_book_imbalance([[50, 100]], [[50, 1000]], 5000)
      assert pts in 45..50
    end

    test "multiple levels per side sum to depth" do
      yes_levels = [[40, 50], [45, 100], [50, 150]]
      no_levels = [[60, 10]]
      pts = KalshiEdgeScorer.compute_book_imbalance(yes_levels, no_levels, 5000)
      assert pts > 0
    end

    test "zero depth on yes side → 0 pts (log undefined)" do
      assert 0 = KalshiEdgeScorer.compute_book_imbalance([], [[50, 100]], 5000)
    end

    test "zero depth on no side → 0 pts" do
      assert 0 = KalshiEdgeScorer.compute_book_imbalance([[50, 100]], [], 5000)
    end

    test "nil levels → 0 pts (defensive)" do
      assert 0 = KalshiEdgeScorer.compute_book_imbalance(nil, nil, 5000)
      assert 0 = KalshiEdgeScorer.compute_book_imbalance([[50, 100]], nil, 5000)
    end

    test "low volume scales the signal down" do
      pts_low = KalshiEdgeScorer.compute_book_imbalance([[50, 1000]], [[50, 100]], 100)
      pts_high = KalshiEdgeScorer.compute_book_imbalance([[50, 1000]], [[50, 100]], 5000)
      assert pts_low < pts_high
      assert pts_low > 0
    end

    test "nil volume → 0 pts (no signal without volume to weight it)" do
      assert 0 = KalshiEdgeScorer.compute_book_imbalance([[50, 1000]], [[50, 100]], nil)
    end

    test "malformed level entries are skipped, not raised" do
      yes_levels = [[50, 100], "garbage", [60, 50], nil]
      pts = KalshiEdgeScorer.compute_book_imbalance(yes_levels, [[50, 10]], 5000)
      # 150 vs 10 = 15x → saturates at 50 pts × volume weight 5 → caps 50
      assert pts > 0
    end
  end

  describe "score_market/2 — combined time_decay + book_imbalance" do
    test "95% yes at +1h with 10x yes-favored book → :strong" do
      market = %{
        ticker: "KXTEST-26FOO",
        status: "open",
        yes_bid: 94,
        yes_ask: 96,
        close_time: in_hours(1),
        yes_levels: [[95, 1000]],
        no_levels: [[5, 100]],
        volume_24h: 5000
      }

      row = KalshiEdgeScorer.score_market(market, now())
      assert row.breakdown.time_decay in 40..50
      assert row.breakdown.book_imbalance in 40..50
      assert row.score >= 75
      assert row.recommendation == :strong
    end

    test "85% yes at +12h with balanced book → :moderate" do
      market = %{
        ticker: "KXTEST-26FOO",
        status: "open",
        yes_bid: 84,
        yes_ask: 86,
        close_time: in_hours(12),
        yes_levels: [[85, 100]],
        no_levels: [[15, 100]],
        volume_24h: 5000
      }

      row = KalshiEdgeScorer.score_market(market, now())
      assert row.breakdown.book_imbalance == 0
      # decisiveness 0.35 × urgency 0.5 × 50 = 8.75 → score ~9
      assert row.score < 50
    end

    test "totals never exceed 100" do
      market = %{
        ticker: "KXTEST-26FOO",
        status: "open",
        yes_bid: 99,
        yes_ask: 99,
        close_time: in_hours(0.01),
        yes_levels: [[99, 100_000]],
        no_levels: [[1, 1]],
        volume_24h: 100_000
      }

      row = KalshiEdgeScorer.score_market(market, now())
      assert row.score <= 100
    end
  end

  describe "score_markets/2 — list helper" do
    test "scores each market independently" do
      markets = [
        %{ticker: "KX-A", status: "open", yes_bid: 94, yes_ask: 96, close_time: in_hours(1)},
        %{ticker: "KX-B", status: "closed", yes_bid: 94, yes_ask: 96, close_time: in_hours(1)}
      ]

      [a, b] = KalshiEdgeScorer.score_markets(markets, now())
      assert a.ticker == "KX-A" and a.breakdown.time_decay > 0
      assert b.ticker == "KX-B" and b.score == 0
    end

    test "empty list returns []" do
      assert KalshiEdgeScorer.score_markets([], now()) == []
    end
  end
end
