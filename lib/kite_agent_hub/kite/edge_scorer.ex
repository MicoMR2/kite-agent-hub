defmodule KiteAgentHub.Kite.EdgeScorer do
  @moduledoc """
  Computes a 0-100 edge score for a market based on PriceOracle data.

  Scoring breakdown (mirrors QRB methodology):
    - Trend score  (0-40): momentum direction and strength
    - RSI score    (0-30): proximity to optimal RSI range (40-60)
    - Volume score (0-20): volume relative to thresholds by asset
    - Change score (0-10): magnitude of 24h move without extremes

  Returns a recommendation:
    - score >= 75 → :go      (strong edge, trade signal)
    - score 50-74 → :hold    (moderate, wait for confirmation)
    - score < 50  → :no      (poor edge, avoid)
  """

  alias KiteAgentHub.Kite.PriceOracle

  @markets ["ETH-USDC", "BTC-USDC", "KITE-USDC"]

  # Volume thresholds (USD) for scoring — rough daily volume benchmarks
  @volume_thresholds %{
    "ETH-USDC"  => 15_000_000_000,
    "BTC-USDC"  => 30_000_000_000,
    "KITE-USDC" => 50_000_000
  }

  @doc """
  Score all supported markets. Returns a list of score maps, each with:
    %{market, price, change_24h, trend, rsi, volume_24h, score, recommendation, breakdown}
  """
  def score_all do
    @markets
    |> Enum.map(&score_market/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Score a single market symbol. Returns nil on error.
  """
  def score_market(market) do
    case PriceOracle.get(market) do
      {:ok, data} -> compute_score(data)
      {:error, _} -> nil
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp compute_score(data) do
    trend_pts  = trend_score(data.trend)
    rsi_pts    = rsi_score(data.rsi)
    volume_pts = volume_score(data.market, data.volume_24h)
    change_pts = change_score(data.change_24h)

    total = trend_pts + rsi_pts + volume_pts + change_pts

    %{
      market:          data.market,
      price:           data.price,
      change_24h:      data.change_24h,
      trend:           data.trend,
      rsi:             data.rsi,
      volume_24h:      data.volume_24h,
      score:           total,
      recommendation:  recommend(total),
      breakdown: %{
        trend:  trend_pts,
        rsi:    rsi_pts,
        volume: volume_pts,
        change: change_pts
      }
    }
  end

  # Trend: 0-40 pts
  defp trend_score("strongly_bullish"), do: 40
  defp trend_score("bullish"),          do: 30
  defp trend_score("neutral"),          do: 20
  defp trend_score("bearish"),          do: 10
  defp trend_score("strongly_bearish"), do: 0
  defp trend_score(_),                  do: 20

  # RSI: 0-30 pts — peak at RSI 50, tails off at extremes
  defp rsi_score(rsi) when is_integer(rsi) do
    distance = abs(rsi - 50)
    cond do
      distance <= 5  -> 30
      distance <= 10 -> 25
      distance <= 15 -> 18
      distance <= 20 -> 10
      true           -> 0
    end
  end
  defp rsi_score(_), do: 15

  # Volume: 0-20 pts
  defp volume_score(market, volume) when is_integer(volume) and volume > 0 do
    threshold = Map.get(@volume_thresholds, market, 1_000_000_000)
    ratio = volume / threshold
    cond do
      ratio >= 1.5 -> 20
      ratio >= 1.0 -> 16
      ratio >= 0.5 -> 10
      ratio >= 0.2 -> 5
      true         -> 0
    end
  end
  defp volume_score(_, _), do: 10

  # 24h change magnitude: 0-10 pts (reward moderate moves, penalize extremes)
  defp change_score(change) when is_float(change) or is_integer(change) do
    abs_change = abs(change)
    cond do
      abs_change >= 1.0 and abs_change <= 5.0 -> 10
      abs_change > 0.3 and abs_change < 1.0   -> 6
      abs_change > 5.0 and abs_change <= 10.0 -> 4
      abs_change > 10.0                        -> 0
      true                                     -> 3
    end
  end
  defp change_score(_), do: 5

  defp recommend(score) when score >= 75, do: :go
  defp recommend(score) when score >= 50, do: :hold
  defp recommend(_score),                 do: :no
end
