defmodule KiteAgentHub.Kite.KalshiMarketScorer do
  @moduledoc """
  Scores Kalshi markets on a 0-100 scale so callers can filter
  `/api/v1/market-data/kalshi?min_score=N` to just the tradeable
  contracts. Phorari PR #5 scope (msg 6316).

  Formula (stage 1 — simple, shippable, no fair-value model):

    score = 0.6 * volume_score + 0.4 * spread_score

  - `volume_score`   : `min(volume_24h / 1000, 1) * 100` — saturates at
    1000 contracts/24h which maps to a "liquid enough" threshold on
    Kalshi's typical event contracts.
  - `spread_score`   : `max(0, (20 - spread_cents) / 20) * 100`, where
    `spread_cents = yes_ask - yes_bid` in the 0..100 cent Kalshi price
    space. Tight book → high score.

  Floor rules (hard-zero anything untradeable):
  - `volume_24h < 10`         → score 0  (dead market)
  - `spread_cents > 20`       → score 0  (no price discovery)
  - `status != "open"`        → score 0  (not tradeable)

  `recent_fill_count` was in the original Phorari spec but Kalshi's
  `/markets` endpoint does not expose per-market fills — pulling them
  would be one HTTP call per market, which blows the quota on a scan.
  Dropped to keep the scan cheap; deferred to a stage-2 scorer that
  could batch `/markets/trades` lookups for the top-N by liquidity.
  """

  @volume_weight 0.6
  @spread_weight 0.4

  @volume_saturation 1000
  @max_spread_cents 20
  @min_volume 10

  @type score_row :: %{
          ticker: String.t(),
          score: non_neg_integer(),
          volume_24h: number() | nil,
          yes_bid: number() | nil,
          yes_ask: number() | nil,
          spread_cents: number() | nil,
          status: String.t() | nil,
          close_time: String.t() | nil,
          title: String.t() | nil
        }

  @spec score_market(map()) :: score_row()
  def score_market(market) when is_map(market) do
    ticker = market["ticker"] || market["market_ticker"]
    status = market["status"]
    volume_24h = numeric(market["volume_24h"]) || numeric(market["volume"])
    yes_bid = numeric(market["yes_bid"])
    yes_ask = numeric(market["yes_ask"])

    spread = spread_cents(yes_bid, yes_ask)

    raw_score =
      cond do
        status != "open" -> 0.0
        is_nil(volume_24h) or volume_24h < @min_volume -> 0.0
        is_nil(spread) or spread > @max_spread_cents -> 0.0
        true -> combine(volume_24h, spread)
      end

    %{
      ticker: ticker,
      score: raw_score |> Float.round() |> trunc(),
      volume_24h: volume_24h,
      yes_bid: yes_bid,
      yes_ask: yes_ask,
      spread_cents: spread,
      status: status,
      close_time: market["close_time"],
      title: market["title"] || market["subtitle"]
    }
  end

  @spec score_markets([map()], non_neg_integer()) :: [score_row()]
  def score_markets(markets, min_score \\ 0) when is_list(markets) do
    markets
    |> Enum.map(&score_market/1)
    |> Enum.filter(&(&1.score >= min_score))
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp combine(volume, spread) do
    volume_component = min(volume / @volume_saturation, 1.0) * 100.0
    spread_component = max(0.0, (@max_spread_cents - spread) / @max_spread_cents) * 100.0
    @volume_weight * volume_component + @spread_weight * spread_component
  end

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
