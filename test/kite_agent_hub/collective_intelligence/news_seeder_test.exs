defmodule KiteAgentHub.CollectiveIntelligence.NewsSeederTest do
  use KiteAgentHub.DataCase, async: true

  alias KiteAgentHub.CollectiveIntelligence
  alias KiteAgentHub.CollectiveIntelligence.{NewsSeeder, TradeInsight}
  alias KiteAgentHub.Repo

  describe "classify_sentiment/1" do
    test "returns :positive on clear bullish phrasing" do
      assert NewsSeeder.classify_sentiment("AAPL beats Q2 earnings, surges 5%") == :positive
      assert NewsSeeder.classify_sentiment("NVDA rallies on guidance upgrade") == :positive
      assert NewsSeeder.classify_sentiment("Strong growth boosts MSFT outlook") == :positive
    end

    test "returns :negative on clear bearish phrasing" do
      assert NewsSeeder.classify_sentiment("TSLA misses guidance, falls 8%") == :negative
      assert NewsSeeder.classify_sentiment("AMD downgraded as concerns mount") == :negative
      assert NewsSeeder.classify_sentiment("Weak demand drops META") == :negative
    end

    test "returns :neutral when no directional words match" do
      assert NewsSeeder.classify_sentiment("Apple announces new product line") == :neutral
      assert NewsSeeder.classify_sentiment("Company files Q2 10-Q with SEC") == :neutral
    end

    test "returns :neutral when positive and negative words tie" do
      # 1 positive (gains) + 1 negative (cuts) = tie → :neutral
      assert NewsSeeder.classify_sentiment("Gains offset by cost cuts") == :neutral
    end

    test "ignores case" do
      assert NewsSeeder.classify_sentiment("AAPL BEATS EARNINGS") == :positive
      assert NewsSeeder.classify_sentiment("Tsla MISSES expectations") == :negative
    end

    test "tolerates non-binary input by returning :neutral" do
      assert NewsSeeder.classify_sentiment(nil) == :neutral
      assert NewsSeeder.classify_sentiment(123) == :neutral
    end
  end

  describe "insights_from_articles/2" do
    defp article(opts) do
      %{
        "headline" => Keyword.get(opts, :headline, ""),
        "summary" => Keyword.get(opts, :summary, ""),
        "symbols" => Keyword.get(opts, :symbols, []),
        "created_at" => Keyword.get(opts, :ts, "2026-05-04T12:00:00Z")
      }
    end

    test "skips neutral-sentiment articles entirely" do
      attrs =
        NewsSeeder.insights_from_articles(
          [article(headline: "Apple files routine 10-Q", symbols: ["AAPL"])],
          platform: "alpaca",
          market_class: "equity"
        )

      assert attrs == []
    end

    test "skips articles with empty symbols" do
      attrs =
        NewsSeeder.insights_from_articles(
          [article(headline: "AAPL beats earnings", symbols: [])],
          platform: "alpaca",
          market_class: "equity"
        )

      assert attrs == []
    end

    test "produces a long-profit + short-loss pair on positive sentiment" do
      attrs =
        NewsSeeder.insights_from_articles(
          [article(headline: "AAPL beats earnings, surges 5%", symbols: ["AAPL"])],
          platform: "alpaca",
          market_class: "equity"
        )

      assert length(attrs) == 2

      long = Enum.find(attrs, &(&1.side == "long"))
      short = Enum.find(attrs, &(&1.side == "short"))

      assert long.outcome_bucket == "profit"
      assert short.outcome_bucket == "loss"
    end

    test "produces a long-loss + short-profit pair on negative sentiment" do
      attrs =
        NewsSeeder.insights_from_articles(
          [article(headline: "TSLA misses guidance, falls", symbols: ["TSLA"])],
          platform: "alpaca",
          market_class: "equity"
        )

      assert length(attrs) == 2

      long = Enum.find(attrs, &(&1.side == "long"))
      short = Enum.find(attrs, &(&1.side == "short"))

      assert long.outcome_bucket == "loss"
      assert short.outcome_bucket == "profit"
    end

    test "emits one pair per symbol when an article tags multiple tickers" do
      attrs =
        NewsSeeder.insights_from_articles(
          [
            article(
              headline: "Strong tech earnings rally",
              symbols: ["AAPL", "MSFT", "NVDA"]
            )
          ],
          platform: "alpaca",
          market_class: "equity"
        )

      # 3 symbols × 2 sides = 6 attrs
      assert length(attrs) == 6
    end

    test "rerun produces identical source_trade_hash for idempotent insert" do
      a = article(headline: "AAPL beats earnings", symbols: ["AAPL"], ts: "2026-05-04T12:00:00Z")

      first = NewsSeeder.insights_from_articles([a], platform: "alpaca", market_class: "equity")
      second = NewsSeeder.insights_from_articles([a], platform: "alpaca", market_class: "equity")

      assert Enum.map(first, & &1.source_trade_hash) ==
               Enum.map(second, & &1.source_trade_hash)
    end
  end

  describe "record_synthetic_outcome integration" do
    test "first insert succeeds; rerun is a clean no-op via on_conflict :nothing" do
      a = %{
        "headline" => "MSFT surges on strong cloud growth",
        "symbols" => ["MSFT"],
        "created_at" => "2026-05-04T12:00:00Z"
      }

      [attrs | _] =
        NewsSeeder.insights_from_articles([a], platform: "alpaca", market_class: "equity")

      assert :ok = CollectiveIntelligence.record_synthetic_outcome(attrs)
      assert :ok = CollectiveIntelligence.record_synthetic_outcome(attrs)

      count =
        Repo.aggregate(
          from(i in TradeInsight, where: i.source_trade_hash == ^attrs.source_trade_hash),
          :count
        )

      assert count == 1
    end
  end
end
