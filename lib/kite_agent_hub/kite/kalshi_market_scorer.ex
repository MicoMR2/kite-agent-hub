defmodule KiteAgentHub.Kite.KalshiMarketScorer do
  @moduledoc """
  Scores Kalshi markets on a 0-100 scale so callers can filter
  `/api/v1/market-data/kalshi?min_score=N` to just the tradeable
  contracts. Phorari PR #5 scope (msg 6316).

  This is a **tradability** score (Phorari lock msg 6320) — it answers
  "can I get filled on a timely contract?", NOT "does this contract
  have positive expected value?" Equity QRB scores and Kalshi scores
  share the 0-100 scale but mean different things, so every score row
  carries an explicit `score_type: "tradability"` field. Agents must
  not apply the same threshold rules across platforms without that
  distinction.

  Formula (Phorari lock msg 6325 — 40/30/30 vol/spread/time):

    score = 0.4 * volume_score
          + 0.3 * spread_score
          + 0.3 * time_score

    time_score = max(0, 100 - days_to_close * 5)

  - `volume_score`   : `min(volume_24h / 1000, 1) * 100` — saturates at
    1000 contracts/24h which maps to a "liquid enough" threshold on
    Kalshi's typical event contracts.
  - `spread_score`   : `max(0, (20 - spread_cents) / 20) * 100`, where
    `spread_cents = yes_ask - yes_bid` in the 0..100 cent Kalshi price
    space. Tight book → high score.
  - `time_score`     : linear decay. Resolving in <1 day = 95, ~3 days
    = 85, ~7 days = 65, ~20 days = 0. Matches the Kalshi pattern where
    short-dated actively-trading contracts are the high-urgency
    actionable ones (strategy-agent recommendation via Mico msg 6318).

  Floor rules (hard-zero anything untradeable):
  - `status != "open"`        → score 0  (not tradeable at all)
  - `volume_24h < 10`         → score 0  (dead market)
  - `spread_cents > 20`       → liquidity_score 0 (no price discovery)
  - `close_time` past or nil  → time_score 0

  `recent_fill_count` was in the original Phorari spec (msg 6316) but
  Kalshi's `/markets` endpoint does not expose per-market fills —
  pulling them would be one HTTP call per market, which blows the
  quota on a scan. Deferred to a stage-2 scorer that could batch
  `/markets/trades` lookups for the top-N by liquidity.
  """

  @volume_weight 0.4
  @spread_weight 0.3
  @time_weight 0.3

  @volume_saturation 1000
  @max_spread_cents 20
  @min_volume 10
  # Linear decay: 1 day out = 95, 5 days out = 75, 20 days out = 0.
  # `100 - days * 5` matches Phorari's lock in msg 6320.
  @days_decay_slope 5

  @type score_row :: %{
          ticker: String.t(),
          score: non_neg_integer(),
          score_type: String.t(),
          volume_24h: number() | nil,
          yes_bid: number() | nil,
          yes_ask: number() | nil,
          spread_cents: number() | nil,
          days_to_close: float() | nil,
          status: String.t() | nil,
          close_time: String.t() | nil,
          title: String.t() | nil,
          breakdown: %{
            volume: non_neg_integer(),
            spread: non_neg_integer(),
            time: non_neg_integer()
          }
        }

  @spec score_market(map()) :: score_row()
  @spec score_market(map(), DateTime.t()) :: score_row()
  def score_market(market, now \\ DateTime.utc_now()) when is_map(market) do
    ticker = market["ticker"] || market["market_ticker"]
    status = market["status"]
    volume_24h = numeric(market["volume_24h"]) || numeric(market["volume"])
    yes_bid = numeric(market["yes_bid"])
    yes_ask = numeric(market["yes_ask"])
    close_time_raw = market["close_time"]
    days_to_close = days_to_close(close_time_raw, now)

    spread = spread_cents(yes_bid, yes_ask)

    {volume_score, spread_score} =
      cond do
        status != "open" -> {0.0, 0.0}
        is_nil(volume_24h) or volume_24h < @min_volume -> {0.0, 0.0}
        is_nil(spread) or spread > @max_spread_cents -> {0.0, 0.0}
        true -> {volume_component(volume_24h), spread_component(spread)}
      end

    time_score =
      cond do
        status != "open" -> 0.0
        is_nil(days_to_close) -> 0.0
        days_to_close < 0 -> 0.0
        true -> max(0.0, 100.0 - days_to_close * @days_decay_slope)
      end

    final =
      @volume_weight * volume_score +
        @spread_weight * spread_score +
        @time_weight * time_score

    %{
      ticker: ticker,
      score: final |> Float.round() |> trunc(),
      score_type: "tradability",
      volume_24h: volume_24h,
      yes_bid: yes_bid,
      yes_ask: yes_ask,
      spread_cents: spread,
      days_to_close: days_to_close,
      status: status,
      close_time: close_time_raw,
      title: market["title"] || market["subtitle"],
      breakdown: %{
        volume: volume_score |> Float.round() |> trunc(),
        spread: spread_score |> Float.round() |> trunc(),
        time: time_score |> Float.round() |> trunc()
      }
    }
  end

  @spec score_markets([map()], non_neg_integer()) :: [score_row()]
  def score_markets(markets, min_score \\ 0) when is_list(markets) do
    now = DateTime.utc_now()

    markets
    |> Enum.map(&score_market(&1, now))
    |> Enum.filter(&(&1.score >= min_score))
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp volume_component(volume), do: min(volume / @volume_saturation, 1.0) * 100.0

  defp spread_component(spread),
    do: max(0.0, (@max_spread_cents - spread) / @max_spread_cents) * 100.0

  defp days_to_close(nil, _now), do: nil

  defp days_to_close(iso8601, now) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _offset} -> DateTime.diff(dt, now, :second) / 86_400
      _ -> nil
    end
  end

  defp days_to_close(_, _), do: nil

  defp spread_cents(nil, _), do: nil
  defp spread_cents(_, nil), do: nil
  defp spread_cents(bid, ask) when is_number(bid) and is_number(ask), do: ask - bid
  defp spread_cents(_, _), do: nil

  defp numeric(n) when is_number(n), do: n

  defp numeric(n) when is_binary(n) do
    case Float.parse(n) do
      {v, _} -> v
      :error -> nil
    end
  end

  defp numeric(_), do: nil
end
