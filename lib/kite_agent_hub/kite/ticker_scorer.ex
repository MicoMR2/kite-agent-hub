defmodule KiteAgentHub.Kite.TickerScorer do
  @moduledoc """
  Scores a hypothetical NEW entry for a ticker on the same QRB 0-100 scale
  used by `PortfolioEdgeScorer`, but driven entirely by recent OHLCV bars
  rather than an existing position.

  Where PortfolioEdgeScorer answers "how is my current position doing?",
  this module answers "should I open a position in this ticker right now?"

  Score breakdown (0-100):
    - Trend (0-30): price vs 20-day SMA, direction of last 5 bars
    - Momentum (0-25): % change over the last 5 bars and 20 bars
    - Volatility / Risk-Reward (0-25): inverse of avg true range, capped
    - Liquidity (0-20): scaled by avg volume; equities cap fast at 20

  Signal recommendation:
    - score >= 75 → :buy
    - score 50-74 → :hold
    - score < 50  → :no
  """

  @type bar :: %{t: any(), o: float() | nil, h: float() | nil, l: float() | nil, c: float() | nil, v: integer()}
  @type score :: %{
          ticker: String.t(),
          score: non_neg_integer(),
          signal: :buy | :hold | :no,
          last_price: float() | nil,
          sma_20: float() | nil,
          change_5d_pct: float(),
          change_20d_pct: float(),
          avg_volume: integer(),
          breakdown: %{
            trend: non_neg_integer(),
            momentum: non_neg_integer(),
            volatility: non_neg_integer(),
            liquidity: non_neg_integer()
          }
        }

  @doc """
  Score a ticker from a list of bars (most-recent last). Returns nil if
  the bar list is empty or has no valid closes — caller can short-circuit
  to a 'no data' response.
  """
  @spec score_ticker(String.t(), [bar()]) :: score() | nil
  def score_ticker(_ticker, []), do: nil

  def score_ticker(ticker, bars) when is_list(bars) do
    closes = bars |> Enum.map(& &1.c) |> Enum.reject(&is_nil/1)

    if closes == [] do
      nil
    else
      last_price = List.last(closes)
      sma_20 = simple_moving_average(closes, 20)
      change_5d = pct_change_over(closes, 5)
      change_20d = pct_change_over(closes, 20)
      avg_volume = avg_volume(bars)
      atr_pct = atr_percent(bars)

      trend = score_trend(last_price, sma_20, closes)
      momentum = score_momentum(change_5d, change_20d)
      volatility = score_volatility(atr_pct)
      liquidity = score_liquidity(avg_volume)

      total = trend + momentum + volatility + liquidity

      %{
        ticker: ticker,
        score: total,
        signal: signal(total),
        last_price: last_price,
        sma_20: sma_20,
        change_5d_pct: Float.round(change_5d, 2),
        change_20d_pct: Float.round(change_20d, 2),
        avg_volume: avg_volume,
        breakdown: %{
          trend: trend,
          momentum: momentum,
          volatility: volatility,
          liquidity: liquidity
        }
      }
    end
  end

  # ── Scoring helpers ─────────────────────────────────────────────────────────

  defp score_trend(nil, _, _), do: 0
  defp score_trend(_, nil, _), do: 0

  defp score_trend(last_price, sma_20, closes) do
    above_sma = last_price > sma_20
    last_5 = closes |> Enum.take(-5)
    monotone_up = monotone?(last_5, :up)
    monotone_down = monotone?(last_5, :down)

    cond do
      above_sma and monotone_up -> 30
      above_sma -> 22
      monotone_up -> 18
      monotone_down -> 4
      true -> 12
    end
  end

  defp score_momentum(change_5d, change_20d) do
    cond do
      change_5d >= 5 and change_20d >= 10 -> 25
      change_5d >= 2 and change_20d >= 5 -> 20
      change_5d >= 0 and change_20d >= 0 -> 15
      change_5d < -5 -> 0
      change_5d < 0 -> 5
      true -> 10
    end
  end

  # Lower volatility (tight ATR) = better risk/reward for a clean entry.
  # ATR% above 6% gets penalized; below 2% rewarded.
  defp score_volatility(nil), do: 10

  defp score_volatility(atr_pct) do
    cond do
      atr_pct < 1.0 -> 25
      atr_pct < 2.0 -> 22
      atr_pct < 3.0 -> 18
      atr_pct < 5.0 -> 12
      atr_pct < 8.0 -> 6
      true -> 2
    end
  end

  defp score_liquidity(0), do: 0

  defp score_liquidity(avg_volume) do
    cond do
      avg_volume >= 5_000_000 -> 20
      avg_volume >= 1_000_000 -> 16
      avg_volume >= 250_000 -> 12
      avg_volume >= 50_000 -> 8
      avg_volume >= 10_000 -> 4
      true -> 1
    end
  end

  defp signal(score) when score >= 75, do: :buy
  defp signal(score) when score >= 50, do: :hold
  defp signal(_), do: :no

  # ── Math helpers ────────────────────────────────────────────────────────────

  defp simple_moving_average(closes, n) do
    sample = Enum.take(closes, -n)

    case length(sample) do
      0 -> nil
      len -> Enum.sum(sample) / len
    end
  end

  defp pct_change_over(closes, n) do
    len = length(closes)

    if len < 2 do
      0.0
    else
      window = min(n + 1, len)
      [first | _] = Enum.take(closes, -window)
      last = List.last(closes)

      if first > 0, do: (last - first) / first * 100, else: 0.0
    end
  end

  defp avg_volume(bars) do
    volumes = bars |> Enum.map(& &1.v) |> Enum.reject(&is_nil/1)

    case volumes do
      [] -> 0
      list -> div(Enum.sum(list), length(list))
    end
  end

  # Average True Range as a percent of the latest close. Cheap proxy for
  # volatility — uses (high - low) / close averaged over the last 14 bars.
  defp atr_percent(bars) do
    sample = Enum.take(bars, -14)

    ranges =
      sample
      |> Enum.map(fn b ->
        cond do
          is_nil(b.h) or is_nil(b.l) or is_nil(b.c) or b.c == 0 -> nil
          true -> (b.h - b.l) / b.c * 100
        end
      end)
      |> Enum.reject(&is_nil/1)

    case ranges do
      [] -> nil
      list -> Enum.sum(list) / length(list)
    end
  end

  defp monotone?(list, _direction) when length(list) < 2, do: false

  defp monotone?(list, :up) do
    list
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> b >= a end)
  end

  defp monotone?(list, :down) do
    list
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [a, b] -> b <= a end)
  end
end
