defmodule KiteAgentHub.Kite.PortfolioEdgeScorer do
  @moduledoc """
  Scores current Alpaca + Kalshi positions and suggests new trades
  using QRB methodology.

  Position scores reflect how strong the current edge is on each holding.
  Suggestions come from scanning available Kalshi markets for mispriced contracts.

  Score breakdown (0-100):
    - Entry Quality (0-30): how good was the entry vs current price
    - Momentum (0-25): is the position moving in your favor
    - Risk/Reward (0-25): current R:R ratio based on entry and limits
    - Liquidity (0-20): can you exit cleanly
  """

  alias KiteAgentHub.{Credentials, Orgs}
  alias KiteAgentHub.TradingPlatforms.{AlpacaClient, KalshiClient}

  @type recommendation :: :strong_hold | :hold | :watch | :exit
  @type position_score :: %{
          platform: :alpaca | :kalshi,
          score: non_neg_integer(),
          recommendation: recommendation(),
          pnl_pct: float(),
          breakdown: %{
            entry_quality: non_neg_integer(),
            momentum: non_neg_integer(),
            risk_reward: non_neg_integer(),
            liquidity: non_neg_integer()
          }
        }
  @type suggestion :: %{action: :exit | :hold, ticker: String.t(), platform: atom(), reason: String.t(), score: non_neg_integer()}
  @type portfolio_scores :: %{
          alpaca_scores: [position_score()],
          kalshi_scores: [position_score()],
          suggestions: [suggestion()],
          timestamp: DateTime.t()
        }

  @doc """
  Score all positions for the given org.

  Fetches current Alpaca and Kalshi positions, runs each through the
  QRB edge scorer, and surfaces up to 5 actionable exit/hold
  suggestions based on the scores.
  """
  @spec score_portfolio(Ecto.UUID.t()) :: portfolio_scores()
  def score_portfolio(org_id) do
    alpaca_scores = score_alpaca_positions(org_id)
    kalshi_scores = score_kalshi_positions(org_id)
    suggestions = generate_suggestions(kalshi_scores, alpaca_scores)

    %{
      alpaca_scores: alpaca_scores,
      kalshi_scores: kalshi_scores,
      suggestions: suggestions,
      timestamp: DateTime.utc_now()
    }
  end

  # ── Alpaca Position Scoring ──────────────────────────────────────────────────

  defp score_alpaca_positions(org_id) do
    case Credentials.fetch_secret_with_env(org_id, :alpaca) do
      {:ok, {key_id, secret, env}} ->
        case AlpacaClient.positions(key_id, secret, env) do
          {:ok, positions} -> Enum.map(positions, &score_alpaca_position/1)
          _ -> []
        end
      _ -> []
    end
  end

  defp score_alpaca_position(pos) do
    entry = pos.avg_entry || 0.0
    current = pos.current_price || 0.0
    pnl_pct = if entry > 0, do: (current - entry) / entry * 100, else: 0.0

    entry_quality = score_entry_quality(pnl_pct)
    momentum = score_momentum(pnl_pct, pos.side)
    risk_reward = score_risk_reward(pnl_pct)
    liquidity = 16  # Alpaca equities generally liquid

    total = entry_quality + momentum + risk_reward + liquidity

    %{
      platform: :alpaca,
      ticker: pos.symbol,
      side: pos.side,
      qty: pos.qty,
      entry_price: entry,
      current_price: current,
      pnl_pct: Float.round(pnl_pct, 2),
      score: total,
      recommendation: recommend(total),
      breakdown: %{
        entry_quality: entry_quality,
        momentum: momentum,
        risk_reward: risk_reward,
        liquidity: liquidity
      }
    }
  end

  # ── Kalshi Position Scoring ──────────────────────────────────────────────────

  defp score_kalshi_positions(org_id) do
    case Credentials.fetch_secret(org_id, :kalshi) do
      {:ok, {key_id, pem}} ->
        case KalshiClient.positions(key_id, pem) do
          {:ok, positions} -> Enum.map(positions, &score_kalshi_position/1)
          _ -> []
        end
      _ -> []
    end
  end

  defp score_kalshi_position(pos) do
    entry = pos.avg_price
    current = pos.current_price
    contracts = pos.contracts

    # Kalshi: edge = how far current price moved from your entry
    pnl_pct = if entry > 0, do: (current - entry) / entry * 100, else: 0.0

    # Kalshi-specific: contracts near 0 or 100 cents have less edge remaining
    edge_remaining = min(current * 100, (1.0 - current) * 100) |> max(0)

    entry_quality = score_entry_quality(pnl_pct)
    momentum = score_kalshi_momentum(current, entry, pos.side)
    risk_reward = score_kalshi_rr(current, entry, pos.side)
    liquidity = if contracts > 0, do: 14, else: 8

    total = entry_quality + momentum + risk_reward + liquidity

    %{
      platform: :kalshi,
      ticker: pos.market_id,
      title: pos.title,
      side: pos.side,
      contracts: contracts,
      entry_price: entry,
      current_price: current,
      edge_remaining: Float.round(edge_remaining, 1),
      pnl_pct: Float.round(pnl_pct, 2),
      score: total,
      recommendation: recommend(total),
      breakdown: %{
        entry_quality: entry_quality,
        momentum: momentum,
        risk_reward: risk_reward,
        liquidity: liquidity
      }
    }
  end

  # ── Suggestions ──────────────────────────────────────────────────────────────

  defp generate_suggestions(kalshi_scores, alpaca_scores) do
    all = kalshi_scores ++ alpaca_scores

    suggestions = []

    # Suggest exiting weak positions
    weak = Enum.filter(all, &(&1.score < 40))
    exit_suggestions = Enum.map(weak, fn pos ->
      %{
        action: :exit,
        ticker: pos[:ticker] || pos[:title],
        platform: pos.platform,
        reason: "Edge score #{pos.score}/100 — below threshold. Consider closing.",
        score: pos.score
      }
    end)

    # Suggest holding strong positions
    strong = Enum.filter(all, &(&1.score >= 75))
    hold_suggestions = Enum.map(strong, fn pos ->
      %{
        action: :hold,
        ticker: pos[:ticker] || pos[:title],
        platform: pos.platform,
        reason: "Strong edge #{pos.score}/100 — maintain position.",
        score: pos.score
      }
    end)

    (exit_suggestions ++ hold_suggestions)
    |> Enum.sort_by(& &1.score)
    |> Enum.take(5)
  end

  # ── Scoring Helpers ──────────────────────────────────────────────────────────

  defp score_entry_quality(pnl_pct) do
    cond do
      pnl_pct >= 10 -> 30
      pnl_pct >= 5 -> 25
      pnl_pct >= 2 -> 20
      pnl_pct >= 0 -> 15
      pnl_pct >= -2 -> 10
      pnl_pct >= -5 -> 5
      true -> 0
    end
  end

  defp score_momentum(pnl_pct, side) do
    # Positive P&L means momentum is with you
    favorable = (side == "long" and pnl_pct > 0) or (side == "short" and pnl_pct < 0)
    magnitude = abs(pnl_pct)

    cond do
      favorable and magnitude >= 5 -> 25
      favorable and magnitude >= 2 -> 20
      favorable -> 15
      magnitude < 1 -> 12
      magnitude < 3 -> 8
      true -> 3
    end
  end

  defp score_kalshi_momentum(current, entry, side) do
    moving_right = (side == "yes" and current > entry) or (side == "no" and current < entry)
    gap = abs(current - entry) * 100

    cond do
      moving_right and gap >= 10 -> 25
      moving_right and gap >= 5 -> 20
      moving_right -> 15
      gap < 3 -> 12
      true -> 5
    end
  end

  defp score_risk_reward(pnl_pct) do
    cond do
      pnl_pct >= 5 -> 25
      pnl_pct >= 2 -> 20
      pnl_pct >= 0 -> 15
      pnl_pct >= -2 -> 10
      pnl_pct >= -5 -> 5
      true -> 0
    end
  end

  defp score_kalshi_rr(current, entry, side) do
    # For YES: potential = (1.0 - current) if you're long, risk = current
    # For NO: potential = current if you're short, risk = (1.0 - current)
    {potential, risk} = case side do
      "yes" -> {1.0 - current, current}
      "no" -> {current, 1.0 - current}
      _ -> {0.5, 0.5}
    end

    ratio = if risk > 0, do: potential / risk, else: 0

    cond do
      ratio >= 3.0 -> 25
      ratio >= 2.0 -> 20
      ratio >= 1.5 -> 15
      ratio >= 1.0 -> 10
      ratio >= 0.5 -> 5
      true -> 0
    end
  end

  defp recommend(score) when score >= 75, do: :strong_hold
  defp recommend(score) when score >= 60, do: :hold
  defp recommend(score) when score >= 40, do: :watch
  defp recommend(_score), do: :exit
end
