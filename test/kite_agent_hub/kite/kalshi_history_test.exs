defmodule KiteAgentHub.Kite.KalshiHistoryTest do
  @moduledoc """
  Hermetic coverage for the PR-I₁ data foundation:

  * `KalshiClient.parse_candlestick/3` — pure parser from the raw
    Kalshi response shape to the integer-cents schema row.
  * `KalshiHistory.valid_row?/1` — pre-insert guard that drops
    placeholder rows missing required fields.

  Live `Repo.insert_all` upsert behavior is exercised separately
  via DataCase integration tests; this file stays parser-only so
  it runs in the async lane.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.Kite.KalshiHistory
  alias KiteAgentHub.TradingPlatforms.KalshiClient

  describe "parse_candlestick/3" do
    test "maps Kalshi yes_price_* keys to schema yes_*_cents" do
      raw = %{
        "end_period_ts" => 1_700_000_000,
        "yes_price_open" => 42,
        "yes_price_close" => 48,
        "yes_price_high" => 55,
        "yes_price_low" => 40,
        "volume" => 1234,
        "open_interest" => 9876
      }

      candle = KalshiClient.parse_candlestick(raw, "KXTEST-26FOO", 5)

      assert candle.ticker == "KXTEST-26FOO"
      assert candle.period_minutes == 5
      assert %DateTime{} = candle.ts
      assert DateTime.to_unix(candle.ts) == 1_700_000_000
      assert candle.yes_open_cents == 42
      assert candle.yes_close_cents == 48
      assert candle.yes_high_cents == 55
      assert candle.yes_low_cents == 40
      assert candle.volume == 1234
      assert candle.open_interest == 9876
    end

    test "falls back to bare open/close/high/low keys" do
      # Some Kalshi candlestick fixtures (esp. on the v1 surface)
      # ship the prices under unprefixed keys.
      raw = %{
        "timestamp" => 1_700_001_000,
        "open" => 10,
        "close" => 15,
        "high" => 20,
        "low" => 8,
        "volume" => 1
      }

      candle = KalshiClient.parse_candlestick(raw, "KXTEST-26FOO", 60)

      assert candle.yes_open_cents == 10
      assert candle.yes_close_cents == 15
      assert candle.yes_high_cents == 20
      assert candle.yes_low_cents == 8
      assert candle.volume == 1
      # open_interest is genuinely absent — must surface as nil, not 0.
      assert candle.open_interest == nil
    end

    test "nil timestamp -> ts is nil (gets dropped by valid_row? later)" do
      raw = %{"yes_price_open" => 50}
      candle = KalshiClient.parse_candlestick(raw, "KXTEST-26FOO", 5)
      assert candle.ts == nil
      refute KalshiHistory.valid_row?(candle)
    end

    test "string unix-ts gets parsed (defensive — Kalshi sometimes ships strings)" do
      raw = %{"end_period_ts" => "1700000000", "yes_price_open" => 50}
      candle = KalshiClient.parse_candlestick(raw, "KXTEST-26FOO", 5)
      assert DateTime.to_unix(candle.ts) == 1_700_000_000
    end
  end

  describe "valid_row?/1" do
    test "rejects rows missing required fields" do
      base = %{
        ticker: "X",
        ts: DateTime.utc_now(),
        period_minutes: 5,
        yes_open_cents: nil
      }

      assert KalshiHistory.valid_row?(base)

      refute KalshiHistory.valid_row?(%{base | ticker: nil})
      refute KalshiHistory.valid_row?(%{base | ts: nil})
      refute KalshiHistory.valid_row?(%{base | period_minutes: 0})
      refute KalshiHistory.valid_row?(%{base | period_minutes: -5})
      refute KalshiHistory.valid_row?(%{})
    end
  end
end
