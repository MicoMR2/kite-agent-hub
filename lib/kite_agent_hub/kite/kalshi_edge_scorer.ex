defmodule KiteAgentHub.Kite.KalshiEdgeScorer do
  @moduledoc """
  0-100 edge score for Kalshi markets mirroring the QRB methodology
  of `KiteAgentHub.Kite.EdgeScorer` (crypto). Distinct from
  `KalshiMarketScorer` which measures TRADABILITY (liquidity + time);
  this scorer measures EDGE / expected value.

  Phase 2 / PR-K1 (Phorari 10747 signals 1+2+3). This module ships
  signal 1 (time-decay / closeout edge). PR-K2 adds signal 2
  (order-book imbalance). Signal 3 (forecaster-aggregate gap) is
  parked behind a new external feed credential surface.

  ## Scoring breakdown (PR-K1)

  Signal 1 — Time-decay / closeout edge (100 pts in this PR; will
  be rebalanced when K2/K3 add additional signals):

    decisiveness = |implied_prob - 0.5| ∈ [0, 0.5]
    urgency = max(0, 1 - hours_to_close / 24) ∈ [0, 1]
    raw = decisiveness × 2 × urgency ∈ [0, 1]
    score = round(raw × 100)

  Intuition: high `decisiveness` flags a market the crowd has
  effectively resolved (implied prob ~ 0 or ~ 1) but that hasn't
  yet settled. High `urgency` flags a market close to its close
  time. The product is the time-decay edge: a market near 95%
  yes one hour before close is a higher-conviction trade than
  the same market a week out.

  Returns `:hard_zero` when the market isn't tradable per the
  lifecycle status or close_time gating — same fail-closed
  defaults as `KalshiMarketScorer`.

  ## Recommendation

    score >= 75 → :strong  (high-conviction edge)
    score 50-74 → :moderate (worth a small position)
    score < 50  → :pass     (no clear edge)

  Signal-only. CyberSec 10749 standing condition: scores recommend,
  never auto-trade. PaperExecutionWorker preflight + DrawdownGate +
  per-trade cap stay the only path to a broker POST.
  """

  alias KiteAgentHub.Kite.KalshiHistory

  @type score_row :: %{
          ticker: String.t(),
          score: non_neg_integer(),
          recommendation: :strong | :moderate | :pass,
          breakdown: %{time_decay: non_neg_integer()},
          implied_prob: float() | nil,
          hours_to_close: float() | nil,
          status: String.t() | nil
        }

  @doc """
  Score a parsed market map (output of `KalshiClient.parse_market/1`
  or `score_market/2` from the market scorer). Defaults `now` to
  current UTC; tests inject a fixed clock for replay determinism.
  """
  @spec score_market(map(), DateTime.t()) :: score_row()
  def score_market(market, now \\ DateTime.utc_now()) when is_map(market) do
    ticker = market[:ticker] || market["ticker"]
    status = market[:status] || market["status"]
    last_cents = market[:last_price_cents] || market[:last_price] || market["last_price"]

    # Accept either the parsed schema (`:yes_bid_cents`, the shape
    # `KalshiClient.parse_market/1` ships) or the raw Kalshi keys
    # (`:yes_bid` / `"yes_bid"`) so callers don't have to round-trip
    # through the parser just to score one market.
    yes_bid =
      market[:yes_bid_cents] || market[:yes_bid] || market["yes_bid_cents"] || market["yes_bid"]

    yes_ask =
      market[:yes_ask_cents] || market[:yes_ask] || market["yes_ask_cents"] || market["yes_ask"]

    close_time = market[:close_time] || market["close_time"]

    implied_prob = implied_prob(last_cents, yes_bid, yes_ask)
    hours_to_close = hours_to_close(close_time, now)

    {time_decay_pts, score} =
      cond do
        status not in ["open", "active"] -> {0, 0}
        is_nil(implied_prob) -> {0, 0}
        is_nil(hours_to_close) or hours_to_close <= 0 -> {0, 0}
        true -> compute_time_decay(implied_prob, hours_to_close)
      end

    %{
      ticker: ticker,
      score: score,
      recommendation: recommend(score),
      breakdown: %{time_decay: time_decay_pts},
      implied_prob: implied_prob,
      hours_to_close: hours_to_close,
      status: status
    }
  end

  @doc """
  Score the agent's open Kalshi positions. Reads each market's
  current implied probability + close time and surfaces the
  per-position edge score. Pure transform — no Kalshi API call;
  caller passes already-fetched market data.

  Used by the `/api/v1/kalshi-edge-scores` endpoint to power the
  KAH dashboard + agent context block.
  """
  @spec score_markets([map()], DateTime.t()) :: [score_row()]
  def score_markets(markets, now \\ DateTime.utc_now()) when is_list(markets) do
    Enum.map(markets, &score_market(&1, now))
  end

  @doc false
  # Pure decision exposed for hermetic tests. Returns
  # `{breakdown_points, total_score}`. Time-decay carries all 100 pts
  # in PR-K1; PR-K2 will rebalance when order-book imbalance lands.
  def compute_time_decay(implied_prob, hours_to_close)
      when is_number(implied_prob) and is_number(hours_to_close) and hours_to_close > 0 do
    decisiveness = abs(implied_prob - 0.5)
    urgency = max(0.0, 1.0 - hours_to_close / 24.0)
    raw = decisiveness * 2.0 * urgency
    score = raw |> Kernel.*(100) |> round() |> min(100) |> max(0)
    {score, score}
  end

  def compute_time_decay(_, _), do: {0, 0}

  # Recommendation thresholds — same shape as EdgeScorer's :go/:hold/:no
  # but with Kalshi-specific atoms so caller dispatch can pattern-match
  # on platform-distinct semantics.
  defp recommend(score) when score >= 75, do: :strong
  defp recommend(score) when score >= 50, do: :moderate
  defp recommend(_), do: :pass

  # Prefer the live mid (avg of bid/ask) over last_price when both
  # are present — last_price drifts stale on illiquid markets.
  defp implied_prob(_last, yes_bid, yes_ask)
       when is_number(yes_bid) and is_number(yes_ask) and yes_bid + yes_ask > 0 do
    (yes_bid + yes_ask) / 2.0 / 100.0
  end

  defp implied_prob(last_cents, _bid, _ask) when is_number(last_cents) and last_cents > 0 do
    last_cents / 100.0
  end

  defp implied_prob(_, _, _), do: nil

  defp hours_to_close(nil, _now), do: nil

  defp hours_to_close(close_time, %DateTime{} = now) when is_binary(close_time) do
    case DateTime.from_iso8601(close_time) do
      {:ok, dt, _} -> DateTime.diff(dt, now, :second) / 3600.0
      _ -> nil
    end
  end

  defp hours_to_close(%DateTime{} = close_dt, %DateTime{} = now),
    do: DateTime.diff(close_dt, now, :second) / 3600.0

  defp hours_to_close(_, _), do: nil

  # KalshiHistory shim — not used in PR-K1 scoring math but kept as
  # an alias hook so PR-K2 (order-book imbalance) and PR-K3 (KCI
  # outcome ingest) can grow this module without re-importing.
  @doc false
  def history_module, do: KalshiHistory
end
