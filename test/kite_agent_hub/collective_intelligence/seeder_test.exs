defmodule KiteAgentHub.CollectiveIntelligence.SeederTest do
  use KiteAgentHub.DataCase, async: true

  alias KiteAgentHub.CollectiveIntelligence
  alias KiteAgentHub.CollectiveIntelligence.{Seeder, TradeInsight}
  alias KiteAgentHub.Repo

  defp bar(close, day_offset) do
    %{
      "c" => close,
      "o" => close,
      "h" => close,
      "l" => close,
      "v" => 1_000_000,
      "t" =>
        DateTime.utc_now()
        |> DateTime.add(day_offset * 86_400, :second)
        |> DateTime.to_iso8601()
    }
  end

  describe "insights_from_bars/2" do
    test "produces zero insights when there are not enough bars to cover hold window" do
      bars = Enum.map(1..5, fn i -> bar(100.0 + i, -i) end)

      attrs =
        Seeder.insights_from_bars(bars,
          platform: "alpaca",
          symbol: "AAPL",
          timeframe: "1Day",
          market_class: "equity",
          hold_bars: 10
        )

      assert attrs == []
    end

    test "produces a long+short pair per entry when bars >= hold + 1" do
      # 12 bars + hold_bars=10 → 2 valid entry indices (0, 1) → 2 pairs = 4 attrs
      bars = Enum.map(1..12, fn i -> bar(100.0 + i, -i) end)

      attrs =
        Seeder.insights_from_bars(bars,
          platform: "alpaca",
          symbol: "AAPL",
          timeframe: "1Day",
          market_class: "equity",
          hold_bars: 10
        )

      assert length(attrs) == 4
      assert Enum.count(attrs, &(&1.side == "long")) == 2
      assert Enum.count(attrs, &(&1.side == "short")) == 2
    end

    test "long outcome is profit when price went up; short outcome is loss" do
      bars =
        Enum.map(1..12, fn i ->
          # Monotonically increasing close so a long is always profit
          bar(100.0 + i * 5, -i)
        end)

      attrs =
        Seeder.insights_from_bars(bars,
          platform: "alpaca",
          symbol: "AAPL",
          timeframe: "1Day",
          market_class: "equity",
          hold_bars: 10
        )

      longs = Enum.filter(attrs, &(&1.side == "long"))
      shorts = Enum.filter(attrs, &(&1.side == "short"))

      assert Enum.all?(longs, &(&1.outcome_bucket == "profit"))
      assert Enum.all?(shorts, &(&1.outcome_bucket == "loss"))
    end

    test "outcomes count as flat when |Δ%| < flat_threshold_pct" do
      # All bars at the same price → 0% change → flat for both sides
      bars = Enum.map(1..12, fn i -> bar(100.0, -i) end)

      attrs =
        Seeder.insights_from_bars(bars,
          platform: "alpaca",
          symbol: "AAPL",
          timeframe: "1Day",
          market_class: "equity",
          hold_bars: 10
        )

      assert Enum.all?(attrs, &(&1.outcome_bucket == "flat"))
    end

    test "tolerates atom-keyed bars (AlpacaClient.bars parsed shape)" do
      # AlpacaClient.bars/5 returns bars with atom keys like %{c: 187.4, t: "..."}.
      # The Seeder must handle both atom-keyed and string-keyed shapes so it
      # works whether the caller passes raw JSON or parsed structs.
      atom_bars =
        Enum.map(1..12, fn i ->
          %{
            c: 100.0 + i,
            o: 100.0 + i,
            h: 100.0 + i,
            l: 100.0 + i,
            v: 1_000_000,
            t:
              DateTime.utc_now()
              |> DateTime.add(-i * 86_400, :second)
              |> DateTime.to_iso8601()
          }
        end)

      attrs =
        Seeder.insights_from_bars(atom_bars,
          platform: "alpaca",
          symbol: "AAPL",
          timeframe: "1Day",
          market_class: "equity",
          hold_bars: 10
        )

      # Should produce the same 4 insights (2 entries × long+short) as the
      # string-keyed version, not collapse to []
      assert length(attrs) == 4
      assert Enum.count(attrs, &(&1.side == "long")) == 2
      assert Enum.count(attrs, &(&1.side == "short")) == 2
    end

    test "rerun produces identical source_trade_hash (idempotent insert)" do
      bars = Enum.map(1..12, fn i -> bar(100.0 + i, -i) end)

      opts = [
        platform: "alpaca",
        symbol: "AAPL",
        timeframe: "1Day",
        market_class: "equity",
        hold_bars: 10
      ]

      first = Seeder.insights_from_bars(bars, opts)
      second = Seeder.insights_from_bars(bars, opts)

      assert Enum.map(first, & &1.source_trade_hash) == Enum.map(second, & &1.source_trade_hash)
    end
  end

  describe "record_synthetic_outcome/1 inserts deduplicate on source_trade_hash" do
    test "first insert succeeds, re-insert is on_conflict :nothing" do
      bars = Enum.map(1..12, fn i -> bar(100.0 + i, -i) end)

      [attrs | _] =
        Seeder.insights_from_bars(bars,
          platform: "alpaca",
          symbol: "AAPL",
          timeframe: "1Day",
          market_class: "equity"
        )

      assert :ok = CollectiveIntelligence.record_synthetic_outcome(attrs)
      assert :ok = CollectiveIntelligence.record_synthetic_outcome(attrs)

      # Still exactly one row for that hash
      count =
        Repo.aggregate(
          from(i in TradeInsight, where: i.source_trade_hash == ^attrs.source_trade_hash),
          :count
        )

      assert count == 1
    end
  end
end
