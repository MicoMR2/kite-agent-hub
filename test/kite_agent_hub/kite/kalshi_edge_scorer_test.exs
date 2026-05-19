defmodule KiteAgentHub.Kite.KalshiEdgeScorerTest do
  @moduledoc """
  Locks the PR-K1 scoring contract for KalshiEdgeScorer (Phorari
  10747 signal 1 — time-decay / closeout edge). Pure math, no
  HTTP, no DB; runs async.

  Key invariants:
  - status not in [open, active] → score 0 + recommendation :pass
  - missing implied prob → score 0
  - past close_time → score 0
  - 95% yes one hour before close → high score, :strong
  - 50% yes any time → score 0 (no decisiveness)
  - 95% yes a week before close → low score, :pass (no urgency)
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.Kite.KalshiEdgeScorer

  defp now, do: DateTime.from_naive!(~N[2026-05-19 18:00:00.000000], "Etc/UTC")
  defp in_hours(h), do: DateTime.add(now(), trunc(h * 3600), :second) |> DateTime.to_iso8601()

  describe "score_market/2 — happy path" do
    test "95% yes one hour before close → high score + :strong recommendation" do
      market = %{
        ticker: "KXTEST-26FOO",
        status: "open",
        yes_bid: 94,
        yes_ask: 96,
        close_time: in_hours(1)
      }

      row = KalshiEdgeScorer.score_market(market, now())

      assert row.score >= 75
      assert row.recommendation == :strong
      assert row.implied_prob == 0.95
      assert_in_delta row.hours_to_close, 1.0, 0.01
      assert row.breakdown.time_decay == row.score
    end

    test "95% no one hour before close → high score" do
      market = %{
        ticker: "KXTEST-26FOO",
        status: "open",
        yes_bid: 4,
        yes_ask: 6,
        close_time: in_hours(1)
      }

      row = KalshiEdgeScorer.score_market(market, now())

      # implied prob 0.05 is symmetric to 0.95 around the 50% pivot
      # → same decisiveness 0.45, same score.
      assert row.score >= 75
      assert row.recommendation == :strong
    end

    test "75% yes 6 hours before close → moderate" do
      market = %{
        ticker: "KXTEST-26FOO",
        status: "open",
        yes_bid: 74,
        yes_ask: 76,
        close_time: in_hours(6)
      }

      row = KalshiEdgeScorer.score_market(market, now())

      # decisiveness 0.25, urgency 0.75 → raw 0.375 → score 38
      # That's actually :pass under the 50 cutoff; assert exact range
      assert row.score in 30..50
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
          close_time: in_hours(1)
        }

        row = KalshiEdgeScorer.score_market(market, now())
        assert row.score == 0, "expected 0 for status=#{inspect(status)}, got #{row.score}"
        assert row.recommendation == :pass
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

      row = KalshiEdgeScorer.score_market(market, now())
      assert row.score == 0
    end

    test "95% yes one week before close → score below moderate (no urgency)" do
      market = %{
        ticker: "KXTEST-26FOO",
        status: "open",
        yes_bid: 94,
        yes_ask: 96,
        close_time: in_hours(168)
      }

      row = KalshiEdgeScorer.score_market(market, now())
      # urgency = max(0, 1 - 168/24) = max(0, -6) = 0 → score 0
      assert row.score == 0
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
      assert row.score >= 75
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
      assert row.score >= 75
    end
  end

  describe "compute_time_decay/2 — pure math" do
    test "returns {pts, score} tuple with pts equal to score in PR-K1" do
      {pts, score} = KalshiEdgeScorer.compute_time_decay(0.95, 1.0)
      assert pts == score
    end

    test "non-numeric inputs return {0, 0}" do
      assert {0, 0} = KalshiEdgeScorer.compute_time_decay(nil, 1.0)
      assert {0, 0} = KalshiEdgeScorer.compute_time_decay(0.95, nil)
      assert {0, 0} = KalshiEdgeScorer.compute_time_decay(0.95, -1)
    end

    test "clamps to 0-100 range" do
      # Pathological: hours_to_close = 0.001 (basically settled now)
      # decisiveness 0.5 (perfect 0/100), urgency ~ 1.0 → raw ~ 1.0
      # → score 100
      {_pts, score} = KalshiEdgeScorer.compute_time_decay(1.0, 0.001)
      assert score in 0..100
    end
  end

  describe "score_markets/2 — list helper" do
    test "scores each market independently" do
      markets = [
        %{ticker: "KX-A", status: "open", yes_bid: 94, yes_ask: 96, close_time: in_hours(1)},
        %{ticker: "KX-B", status: "closed", yes_bid: 94, yes_ask: 96, close_time: in_hours(1)}
      ]

      [a, b] = KalshiEdgeScorer.score_markets(markets, now())
      assert a.ticker == "KX-A" and a.score >= 75
      assert b.ticker == "KX-B" and b.score == 0
    end

    test "empty list returns []" do
      assert KalshiEdgeScorer.score_markets([], now()) == []
    end
  end
end
